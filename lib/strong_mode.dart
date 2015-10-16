// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Types needed to implement "strong" checking in the Dart analyzer. This is
/// intended to be used by `analyzer_cli` and `analysis_server` packages.
library dev_compiler.strong_mode;

import 'package:analyzer/src/generated/engine.dart'
    show
        AnalysisContext,
        AnalysisContextImpl,
        AnalysisEngine,
        AnalysisErrorInfo,
        AnalysisErrorInfoImpl;
import 'package:analyzer/src/generated/error.dart'
    show
        AnalysisError,
        AnalysisErrorListener,
        CompileTimeErrorCode,
        ErrorCode,
        ErrorSeverity,
        HintCode,
        StaticTypeWarningCode;
import 'package:analyzer/src/generated/source.dart' show Source;
import 'package:args/args.dart';

import 'src/analysis_context.dart' show enableDevCompilerInference;
import 'src/checker/checker.dart' show CodeChecker;
import 'src/checker/rules.dart' show TypeRules;

/// A type checker for Dart code that operates under stronger rules, and has
/// the ability to do local type inference in some situations.
// TODO(jmesserly): remove this class.
class StrongChecker {
  final AnalysisContext _context;
  final CodeChecker _checker;
  final _ErrorCollector _reporter;

  StrongChecker._(this._context, this._checker, this._reporter);

  factory StrongChecker(AnalysisContext context, StrongModeOptions options) {
    // TODO(vsm): Remove this once analyzer_cli is completely switched to the
    // task model.
    if (!AnalysisEngine.instance.useTaskModel) {
      enableDevCompilerInference(context, options);
      var rules = new TypeRules(context.typeProvider);
      var reporter = new _ErrorCollector(options.hints);
      var checker = new CodeChecker(rules, reporter);
      return new StrongChecker._(context, checker, reporter);
    }
    return new StrongChecker._(context, null, null);
  }

  /// Computes and returns DDC errors for the [source].
  AnalysisErrorInfo computeErrors(Source source) {
    var errors = new List<AnalysisError>();
    if (_checker != null) {
      _reporter.errors = errors;

      for (Source librarySource in _context.getLibrariesContaining(source)) {
        var resolved = _context.resolveCompilationUnit2(source, librarySource);
        _checker.visitCompilationUnit(resolved);
      }
      _reporter.errors = null;
    }
    return new AnalysisErrorInfoImpl(errors, _context.getLineInfo(source));
  }
}

class _ErrorCollector implements AnalysisErrorListener {
  List<AnalysisError> errors;
  final bool hints;
  _ErrorCollector(this.hints);

  void onError(AnalysisError error) {
    // Unless DDC hints are requested, filter them out.
    var HINT = ErrorSeverity.INFO.ordinal;
    if (hints || error.errorCode.errorSeverity.ordinal > HINT) {
      errors.add(error);
    }
  }
}

// TODO(jmesserly): this type is dead now. It's preserved because analyzer_cli
// passes the `hints` option.
class StrongModeOptions {
  /// Whether to include hints about dynamic invokes and runtime checks.
  // TODO(jmesserly): this option is not used yet by DDC server mode or batch
  // compile to JS.
  final bool hints;

  const StrongModeOptions({this.hints: false});

  StrongModeOptions.fromArguments(ArgResults args, {String prefix: ''})
      : hints = args[prefix + 'hints'];

  static ArgParser addArguments(ArgParser parser,
      {String prefix: '', bool hide: false}) {
    return parser
      ..addFlag(prefix + 'hints',
          help: 'Display hints about dynamic casts and dispatch operations',
          defaultsTo: false,
          hide: hide);
  }

  bool operator ==(Object other) {
    if (other is! StrongModeOptions) return false;
    StrongModeOptions s = other;
    return hints == s.hints;
  }
}
