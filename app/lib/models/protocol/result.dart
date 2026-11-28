import 'package:flutter/foundation.dart';

/// Strongly-typed success/failure result union with zero `dynamic` usage.
@immutable
sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T? get valueOrNull => switch (this) {
        Ok<T, E>(value: final v) => v,
        Err<T, E>() => null,
      };

  E? get errorOrNull => switch (this) {
        Ok<T, E>() => null,
        Err<T, E>(error: final e) => e,
      };

  R when<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  }) =>
      switch (this) {
        Ok<T, E>(value: final v) => ok(v),
        Err<T, E>(error: final e) => err(e),
      };

  Result<U, E> map<U>(U Function(T value) transform) => switch (this) {
        Ok<T, E>(value: final v) => Ok<U, E>(transform(v)),
        Err<T, E>(error: final e) => Err<U, E>(e),
      };

  Result<T, F> mapError<F>(F Function(E error) transform) => switch (this) {
        Ok<T, E>(value: final v) => Ok<T, F>(v),
        Err<T, E>(error: final e) => Err<T, F>(transform(e)),
      };
}

@immutable
final class Ok<T, E> extends Result<T, E> {
  final T value;

  const Ok(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Ok<T, E> && other.value == value);

  @override
  int get hashCode => Object.hash(Ok, value);

  @override
  String toString() => 'Ok($value)';
}

@immutable
final class Err<T, E> extends Result<T, E> {
  final E error;

  const Err(this.error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Err<T, E> && other.error == error);

  @override
  int get hashCode => Object.hash(Err, error);

  @override
  String toString() => 'Err($error)';
}
