import 'telling.dart';

/// A mixin that provides convenient try-catch wrappers with automatic
/// exception reporting to Telling.
///
/// Byte-for-byte the Flutter original apart from one import: the upstream file
/// pulled `VoidCallback` from `package:flutter/foundation.dart`, which is the
/// only Flutter type this mixin actually used.
///
/// Use this mixin in your classes to wrap operations with automatic error
/// capture and reporting.
///
/// ```dart
/// class MyService with TellingTryCatch {
///   Future<User?> fetchUser(String id) async {
///     return tryRun(
///       context: 'fetch_user',
///       metadata: {'user_id': id},
///       func: () async {
///         final response = await api.getUser(id);
///         return User.fromJson(response);
///       },
///     );
///   }
/// }
/// ```
mixin TellingTryCatch {
  /// Executes an async function and automatically captures any exceptions.
  ///
  /// Returns the result of [func] on success, or `null` on failure.
  ///
  /// [func] - The async function to execute
  /// [context] - A label identifying where this operation runs
  /// [metadata] - Additional data to include with any error report
  /// [onSuccess] - Optional callback for successful execution
  /// [onError] - Optional callback invoked after the error is reported
  /// [rethrowException] - If true, rethrow after capturing (default: false)
  Future<T?> tryRun<T>({
    required Future<T> Function() func,
    String? context,
    Map<String, dynamic>? metadata,
    void Function()? onSuccess,
    void Function(Object error, StackTrace stackTrace)? onError,
    bool rethrowException = false,
  }) async {
    try {
      final result = await func();
      onSuccess?.call();
      return result;
    } catch (e, stackTrace) {
      Telling.instance.captureException(
        error: e,
        stackTrace: stackTrace,
        context: context,
        metadata: metadata,
      );

      onError?.call(e, stackTrace);

      if (rethrowException) {
        rethrow;
      }

      return null;
    }
  }

  /// Executes a void async function and automatically captures any exceptions.
  ///
  /// [func] - The async function to execute
  /// [context] - A label identifying where this operation runs
  /// [metadata] - Additional data to include with any error report
  /// [onSuccess] - Optional callback for successful execution
  /// [onError] - Optional callback invoked after the error is reported
  /// [rethrowException] - If true, rethrow after capturing (default: false)
  Future<void> tryRunVoid({
    required Future<void> Function() func,
    String? context,
    Map<String, dynamic>? metadata,
    void Function()? onSuccess,
    void Function(Object error, StackTrace stackTrace)? onError,
    bool rethrowException = false,
  }) async {
    try {
      await func();
      onSuccess?.call();
    } catch (e, stackTrace) {
      Telling.instance.captureException(
        error: e,
        stackTrace: stackTrace,
        context: context,
        metadata: metadata,
      );

      onError?.call(e, stackTrace);

      if (rethrowException) {
        rethrow;
      }
    }
  }

  /// Executes a synchronous function and automatically captures any exceptions.
  ///
  /// Returns the result of [func] on success, or `null` on failure.
  ///
  /// [func] - The synchronous function to execute
  /// [context] - A label identifying where this operation runs
  /// [metadata] - Additional data to include with any error report
  /// [onError] - Optional callback invoked after the error is reported
  /// [rethrowException] - If true, rethrow after capturing (default: false)
  T? tryRunSync<T>({
    required T Function() func,
    String? context,
    Map<String, dynamic>? metadata,
    void Function(Object error, StackTrace stackTrace)? onError,
    bool rethrowException = false,
  }) {
    try {
      return func();
    } catch (e, stackTrace) {
      Telling.instance.captureException(
        error: e,
        stackTrace: stackTrace,
        context: context,
        metadata: metadata,
      );

      onError?.call(e, stackTrace);

      if (rethrowException) {
        rethrow;
      }

      return null;
    }
  }
}
