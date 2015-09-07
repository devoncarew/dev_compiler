// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dev_compiler.src.codegen.js_printer;

import 'dart:io' show Directory, File, Platform, Process;
import 'package:analyzer/src/generated/ast.dart';
import 'package:path/path.dart' as path;
import 'package:source_maps/source_maps.dart' as srcmaps show Printer;
import 'package:source_maps/source_maps.dart' show SourceMapSpan;
import 'package:source_span/source_span.dart' show SourceLocation;

import 'package:dev_compiler/src/js/js_ast.dart' as JS;
import 'package:dev_compiler/src/utils.dart'
    show computeHash, locationForOffset;

import 'js_names.dart' show TemporaryNamer;

String writeJsLibrary(JS.Program jsTree, String outputPath,
    {bool emitSourceMaps: false, bool arrowFnBindThisWorkaround: false,
     bool closure: false}) {
  var outFilename = path.basename(outputPath);
  var outDir = path.dirname(outputPath);
  new Directory(outDir).createSync(recursive: true);

  JS.JavaScriptPrintingContext context;
  if (emitSourceMaps) {
    var printer = new srcmaps.Printer(outFilename);
    context = new SourceMapPrintingContext(printer, outDir);
  } else {
    context = new JS.SimpleJavaScriptPrintingContext();
  }

  var opts = new JS.JavaScriptPrintingOptions(
      closure: closure,
      allowKeywordsInProperties: true,
      arrowFnBindThisWorkaround: arrowFnBindThisWorkaround);
  var jsNamer = new TemporaryNamer(jsTree);
  jsTree.accept(new JS.Printer(opts, context, localNamer: jsNamer));

  String text;
  if (context is SourceMapPrintingContext) {
    var printer = context.printer;
    printer.add('//# sourceMappingURL=$outFilename.map');
    // Write output file and source map
    text = printer.text;
    new File('$outputPath.map').writeAsStringSync(printer.map);
  } else {
    text = (context as JS.SimpleJavaScriptPrintingContext).getText();
  }
  new File(outputPath).writeAsStringSync(text);
  if (jsTree.scriptTag != null) {
    // Mark executable.
    // TODO(jmesserly): should only do this if the input file was executable?
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', outputPath]);
  }

  return computeHash(text);
}

class SourceMapPrintingContext extends JS.JavaScriptPrintingContext {
  final srcmaps.Printer printer;
  final String outputDir;

  CompilationUnit unit;
  Uri uri;

  SourceMapPrintingContext(this.printer, this.outputDir);

  void emit(String string) {
    printer.add(string);
  }

  void enterNode(JS.Node jsNode) {
    AstNode node = jsNode.sourceInformation;
    if (node is CompilationUnit) {
      unit = node;
      uri = _makeRelativeUri(unit.element.source.uri);
      return;
    }
    if (unit == null || node == null || node.offset == -1) return;

    var loc = _location(node.offset);
    var name = _getIdentifier(node);
    if (name != null) {
      // TODO(jmesserly): mark only uses the beginning of the span, but
      // we're required to pass this as a valid span.
      var end = _location(node.end);
      printer.mark(new SourceMapSpan(loc, end, name, isIdentifier: true));
    } else {
      printer.mark(loc);
    }
  }

  SourceLocation _location(int offset) =>
      locationForOffset(unit.lineInfo, uri, offset);

  Uri _makeRelativeUri(Uri src) {
    return new Uri(path: path.relative(src.path, from: outputDir));
  }

  void exitNode(JS.Node jsNode) {
    AstNode node = jsNode.sourceInformation;
    if (node is CompilationUnit) {
      unit = null;
      uri = null;
      return;
    }
    if (unit == null || node == null || node.offset == -1) return;

    // TODO(jmesserly): in many cases marking the end will be unnecessary.
    printer.mark(_location(node.end));
  }

  String _getIdentifier(AstNode node) {
    if (node is SimpleIdentifier) return node.name;
    return null;
  }
}
