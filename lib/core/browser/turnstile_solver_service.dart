/// Turnstile token resolver using InAppWebView.
///
/// Loads the target page in a headless WebView, waits for Turnstile to solve,
/// and extracts the token via JavaScript injection.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Result of a Turnstile solve attempt.
class TurnstileSolveResult {
  final bool ok;
  final String? token;
  final String? error;
  final TurnstileStatus status;

  const TurnstileSolveResult({
    required this.ok,
    this.token,
    this.error,
    required this.status,
  });

  factory TurnstileSolveResult.success(String token) {
    return TurnstileSolveResult(
      ok: true,
      token: token,
      error: null,
      status: TurnstileStatus.tokenObtained,
    );
  }

  factory TurnstileSolveResult.notPresent() {
    return const TurnstileSolveResult(
      ok: false,
      token: null,
      error: 'No Turnstile widget found on page',
      status: TurnstileStatus.notPresent,
    );
  }

  factory TurnstileSolveResult.timeout() {
    return const TurnstileSolveResult(
      ok: false,
      token: null,
      error: 'Timeout waiting for Turnstile token',
      status: TurnstileStatus.timeout,
    );
  }

  factory TurnstileSolveResult.failure(String error) {
    return TurnstileSolveResult(
      ok: false,
      token: null,
      error: error,
      status: TurnstileStatus.failed,
    );
  }
}

enum TurnstileStatus {
  tokenObtained,
  notPresent,
  timeout,
  failed,
}

/// Service for solving Cloudflare Turnstile challenges.
class TurnstileSolverService {
  /// Maximum time to wait for Turnstile to solve (seconds).
  static const int defaultTimeout = 30;

  /// Solves Turnstile on the given URL and returns the token.
  ///
  /// Opens the URL in a headless WebView, waits for Turnstile widget to load
  /// and solve, then extracts the token.
  ///
  /// [url] - Full URL of the page with Turnstile (e.g., login page).
  /// [timeout] - Maximum seconds to wait (default: 30).
  /// [checkPath] - Optional path to check for Turnstile (default: uses [url]).
  Future<TurnstileSolveResult> solve({
    required String url,
    int timeout = defaultTimeout,
    String? checkPath,
  }) async {
    final completer = Completer<TurnstileSolveResult>();
    HeadlessInAppWebView? webView;

    // Timeout timer
    Timer? timeoutTimer = Timer(Duration(seconds: timeout), () {
      if (!completer.isCompleted) {
        completer.complete(TurnstileSolveResult.timeout());
        webView?.dispose();
      }
    });

    try {
      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(checkPath ?? url)),
        onLoadStop: (controller, loadUrl) async {
          // Wait a bit for Turnstile to render
          await Future.delayed(const Duration(seconds: 2));

          // Start polling for token
          _pollForToken(controller, completer, webView!);
        },
        onLoadError: (controller, loadUrl, code, message) {
          if (!completer.isCompleted) {
            completer.complete(
              TurnstileSolveResult.failure('Failed to load page: $message'),
            );
          }
        },
      );

      await webView.run();
      final result = await completer.future;

      timeoutTimer?.cancel();
      await webView.dispose();

      return result;
    } catch (e) {
      timeoutTimer?.cancel();
      await webView?.dispose();
      return TurnstileSolveResult.failure(e.toString());
    }
  }

  /// Polls the page for Turnstile token.
  void _pollForToken(
    InAppWebViewController controller,
    Completer<TurnstileSolveResult> completer,
    HeadlessInAppWebView webView,
  ) {
    const maxAttempts = 30; // 30 attempts × 1s = 30s
    int attempts = 0;

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }

      attempts++;
      if (attempts > maxAttempts) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(TurnstileSolveResult.timeout());
        }
        return;
      }

      try {
        // JavaScript to extract Turnstile token
        final result = await controller.evaluateJavascript(source: '''
(function() {
  try {
    // Method 1: Check for hidden input with Turnstile token
    const input = document.querySelector('input[name="cf-turnstile-response"]');
    if (input && input.value && input.value.length > 20) {
      return { ok: true, token: input.value, method: 'input' };
    }

    // Method 2: Check for Turnstile callback data
    if (window.turnstileToken && window.turnstileToken.length > 20) {
      return { ok: true, token: window.turnstileToken, method: 'callback' };
    }

    // Method 3: Check all textareas (Turnstile sometimes uses textarea)
    const textareas = document.querySelectorAll('textarea[name*="turnstile"], textarea[name*="cf-"]');
    for (const textarea of textareas) {
      if (textarea.value && textarea.value.length > 20) {
        return { ok: true, token: textarea.value, method: 'textarea' };
      }
    }

    // Method 4: Check if Turnstile widget exists but not solved yet
    const iframe = document.querySelector('iframe[src*="challenges.cloudflare.com"]');
    if (iframe) {
      return { ok: false, status: 'waiting', message: 'Turnstile widget found, waiting for solve' };
    }

    // No Turnstile found
    return { ok: false, status: 'not_present', message: 'No Turnstile widget found' };
  } catch (e) {
    return { ok: false, status: 'error', message: e.toString() };
  }
})()
        ''');

        if (result == null) {
          return;
        }

        final data = result is Map ? result : jsonDecode(result.toString());

        if (data['ok'] == true && data['token'] != null) {
          timer.cancel();
          if (!completer.isCompleted) {
            completer.complete(TurnstileSolveResult.success(data['token']));
          }
          return;
        }

        // If status is 'not_present' after a few attempts, conclude no Turnstile
        if (attempts > 5 && data['status'] == 'not_present') {
          timer.cancel();
          if (!completer.isCompleted) {
            completer.complete(TurnstileSolveResult.notPresent());
          }
          return;
        }
      } catch (e) {
        // Continue polling
      }
    });
  }
}
