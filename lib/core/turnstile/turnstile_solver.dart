/// Cloudflare Turnstile token solver using turnstile-bypass skill.
///
/// This service integrates with the turnstile-bypass Python script to obtain
/// Turnstile tokens required for check-in operations on New API sites.
library;

import 'dart:convert';
import 'dart:io';

import '../result/result.dart';
import '../error/app_exception.dart';

/// Result of Turnstile token solving attempt.
class TurnstileResult {
  final bool success;
  final String? token;
  final String? error;
  final String? kind; // 'token' or 'cf_clearance' or 'cf_passed'

  const TurnstileResult({
    required this.success,
    this.token,
    this.error,
    this.kind,
  });

  factory TurnstileResult.fromJson(Map<String, dynamic> json) {
    return TurnstileResult(
      success: json['ok'] as bool? ?? false,
      token: json['token'] as String?,
      error: json['error'] as String?,
      kind: json['kind'] as String?,
    );
  }
}

/// Service for solving Cloudflare Turnstile challenges.
class TurnstileSolver {
  static const _skillPath = '/data/data/com.termux/files/home/.aether/skills/turnstile-bypass';
  static const _solverScript = '$_skillPath/scripts/solve.py';
  static const _pythonPath = '$_skillPath/.venv/bin/python3';

  /// Solves Turnstile challenge for the given URL.
  ///
  /// Returns a [TurnstileResult] with the token if successful.
  /// The token should be used immediately as it has a ~300s TTL.
  Future<Result<TurnstileResult>> solve({
    required String url,
    bool fresh = false,
  }) async {
    try {
      // Check if skill is installed
      final skillDir = Directory(_skillPath);
      if (!await skillDir.exists()) {
        return Failure(
          UnknownException(
            message: 'Turnstile bypass skill not found at $_skillPath',
          ),
        );
      }

      // Build command arguments
      final args = [
        _solverScript,
        '--url',
        url,
      ];

      if (fresh) {
        args.add('--fresh');
      }

      // Execute solve.py script
      final result = await Process.run(
        _pythonPath,
        args,
        workingDirectory: _skillPath,
      );

      if (result.exitCode != 0) {
        return Failure(
          UnknownException(
            message: 'Turnstile solver failed: ${result.stderr}',
          ),
        );
      }

      // Parse JSON output
      final output = result.stdout as String;
      final json = jsonDecode(output.trim()) as Map<String, dynamic>;
      final turnstileResult = TurnstileResult.fromJson(json);

      if (!turnstileResult.success) {
        return Failure(
          NetworkException(
            message: turnstileResult.error ?? 'Failed to solve Turnstile',
          ),
        );
      }

      return Success(turnstileResult);
    } catch (e, st) {
      return Failure(
        UnknownException(
          message: 'Turnstile solver error: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Checks if the Turnstile solver is available and properly configured.
  Future<bool> isAvailable() async {
    try {
      final pythonFile = File(_pythonPath);
      final scriptFile = File(_solverScript);
      return await pythonFile.exists() && await scriptFile.exists();
    } catch (_) {
      return false;
    }
  }
}
