// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dev_compiler.src.html_reporter;

import 'dart:collection' show LinkedHashSet;
import 'dart:convert' show HTML_ESCAPE;
import 'dart:io';

import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart' as yaml;

import '../options.dart';
import '../report.dart';
import '../summary.dart';
import '../../devc.dart';
import 'html_gen.dart';

class HtmlReporter implements AnalysisErrorListener {
  SummaryReporter reporter;
  List<AnalysisError> errors = [];

  HtmlReporter(AnalysisContext context) {
    reporter = new SummaryReporter(context);
  }

  void onError(AnalysisError error) {
    try {
      reporter.onError(error);
    } catch (e, st) {
      print(e);
      print(st);
    }

    errors.add(error);
  }

  void finish(CompilerOptions options) {
    GlobalSummary result = reporter.result;
    print('${errors.length} issues');

    String input = options.inputs.first;
    List<SummaryInfo> summaries = [];

    // Hoist the self-ref package to an `Application` category.
    String packageName = getPackageName();
    if (result.packages.containsKey(packageName)) {
      PackageSummary summary = result.packages[packageName];
      List<MessageSummary> issues = summary.libraries.values
          .expand((LibrarySummary l) => l.messages)
          .toList();
      summaries.add(new SummaryInfo(
          'Application', packageName, 'package:${packageName}', issues));
    }

    List<String> keys = result.packages.keys.toList()..sort();
    for (String name in keys) {
      if (name == packageName) continue;

      PackageSummary summary = result.packages[name];
      List<MessageSummary> issues = summary.libraries.values
          .expand((LibrarySummary summary) => summary.messages)
          .toList();
      summaries
          .add(new SummaryInfo('Packages', name, 'package:${name}', issues));
    }

    keys = result.system.keys.toList()..sort();
    for (String name in keys) {
      LibrarySummary summary = result.system[name];
      summaries.add(
          new SummaryInfo('System', name, 'dart:${name}', summary.messages));
    }

    if (result.loose.isNotEmpty) {
      List<MessageSummary> issues = result.loose.values
          .expand((IndividualSummary summary) => summary.messages)
          .toList();
      summaries.add(new SummaryInfo('Files', 'files', 'files', issues));
    }

    Page page = new Page('Compilation Report', input, summaries);
    String path = '${input.replaceAll('.', '_')}_results.html';
    new File(path).writeAsStringSync(page.create());
    print('Compilation report available at ${path}');
  }

  String getPackageName() {
    File file = new File('pubspec.yaml');
    if (file.existsSync()) {
      var doc = yaml.loadYaml(file.readAsStringSync());
      return doc['name'];
    } else {
      return null;
    }
  }
}

class SummaryInfo {
  int _compareIssues(MessageSummary a, MessageSummary b) {
    int result = _compareSeverity(a.level, b.level);
    if (result != 0) return result;
    result = a.span.sourceUrl.toString().compareTo(b.span.sourceUrl.toString());
    if (result != 0) return result;
    return a.span.start.compareTo(b.span.start);
  }

  static const _sevTable = const {'error': 0, 'warning': 1, 'info': 2};

  int _compareSeverity(String a, String b) => _sevTable[a] - _sevTable[b];

  final String category;
  final String shortTitle;
  final String longTitle;
  final List<MessageSummary> issues;

  SummaryInfo(this.category, this.shortTitle, this.longTitle, this.issues) {
    issues.sort(_compareIssues);
  }

  String get ref => longTitle.replaceAll(':', '_');

  int get errorCount => issues.where((i) => i.level == 'error').length;
  int get warningCount => issues.where((i) => i.level == 'warning').length;
  int get infoCount => issues.where((i) => i.level == 'info').length;

  bool get hasIssues => issues.isNotEmpty;
}

class Page extends HtmlGen {
  final String pageTitle;
  final String inputFile;
  final List<SummaryInfo> summaries;

  Page(this.pageTitle, this.inputFile, this.summaries);

  String get subTitle => inputFile;

  String create() {
    start(
        title: pageTitle,
        theme: 'http://primercss.io/docs.css',
        inlineStyle: _css);

    header();
    startTag('div', classes: "container");
    startTag('div', classes: "columns docs-layout");

    startTag('div', classes: "column one-fourth");
    nav();
    endTag(); // div.column.one-fourth

    startTag('div', classes: "column three-fourths");
    subtitle();
    contents();
    endTag(); // div.column.one-fourths

    endTag(); // div.columns.docs-layout
    footer();
    endTag(); // div.container
    end();

    return toString();
  }

  void header() {
    startTag('header', classes: "masthead");
    startTag('div', classes: "container");
    title();
    startTag('nav', classes: "masthead-nav");
    tag("a",
        href:
            "https://github.com/dart-lang/dev_compiler/blob/master/STRONG_MODE.md",
        contents: "Strong mode");
    endTag(); // nav.masthead-nav
    endTag(); // div.container
    endTag(); // header
  }

  void title() {
    tag("a", classes: "masthead-logo", contents: pageTitle);
  }

  void subtitle() {
    tag("h1", contents: subTitle, classes: "page-title");
  }

  void contents() {
    int errors = summaries.fold(
        0, (int count, SummaryInfo info) => count + info.errorCount);
    int warnings = summaries.fold(
        0, (int count, SummaryInfo info) => count + info.warningCount);
    int infos = summaries.fold(
        0, (int count, SummaryInfo info) => count + info.infoCount);

    List<String> messages = [];

    if (errors > 0) {
      messages.add("${_comma(errors)} ${_pluralize(errors, 'error')}");
    }
    if (warnings > 0) {
      messages.add("${_comma(warnings)} ${_pluralize(warnings, 'warning')}");
    }
    if (infos > 0) {
      messages.add("${_comma(infos)} ${_pluralize(infos, 'info')}");
    }

    String message;

    if (messages.isEmpty) {
      message = 'no issues';
    } else {
      message = messages.join(', ');
    }

    tag("p", contents: 'Found ${message} compiling ${inputFile}.');

    for (SummaryInfo info in summaries) {
      if (!info.hasIssues) continue;

      tag("h2", contents: info.longTitle, attributes: "id=${info.ref}");
      contentItem(info);
    }
  }

  void nav() {
    startTag("nav", classes: "menu docs-menu");
    Iterable<String> categories =
        new LinkedHashSet.from(summaries.map((s) => s.category));
    for (String category in categories) {
      navItems(category, summaries.where((s) => s.category == category));
    }
    endTag();
  }

  void navItems(String category, List<SummaryInfo> infos) {
    if (infos.isEmpty) return;

    tag("span", classes: "menu-heading", contents: category);

    for (SummaryInfo info in infos) {
      if (info.hasIssues) {
        startTag("a", classes: "menu-item", attributes: 'href="#${info.ref}"');

        tag("span", contents: info.shortTitle);

        int errors = info.errorCount;
        int warnings = info.warningCount;
        int infos = info.infoCount;

        if (infos > 0) {
          tag("span", classes: "counter info", contents: '${_comma(infos)}');
        }
        if (warnings > 0) {
          tag("span",
              classes: "counter warning", contents: '${_comma(warnings)}');
        }
        if (errors > 0) {
          tag("span", classes: "counter error", contents: '${_comma(errors)}');
        }

        endTag();
      } else {
        tag("a", classes: "menu-item", contents: info.shortTitle);
      }
    }
  }

  void footer() {
    startTag('footer', classes: "footer");
    writeln(
        "Compilation report from ${inputFile} • DDC version ${devCompilerVersion}");
    endTag();
  }

  void contentItem(SummaryInfo info) {
    int errors = info.errorCount;
    int warnings = info.warningCount;
    int infos = info.infoCount;

    if (errors > 0) {
      tag('span',
          classes: 'counter error',
          contents: '${_comma(errors)} ${_pluralize(errors, 'error')}');
    }
    if (warnings > 0) {
      tag('span',
          classes: 'counter warning',
          contents: '${_comma(warnings)} ${_pluralize(warnings, 'warning')}');
    }
    if (infos > 0) {
      tag('span',
          classes: 'counter info',
          contents: '${_comma(infos)} ${_pluralize(infos, 'info')}');
    }

    info.issues.forEach(emitMessage);
  }

  void emitMessage(MessageSummary issue) {
    startTag('div', classes: 'file');
    startTag('div', classes: 'file-header');
    tag('span', classes: 'counter ${issue.level}', contents: issue.kind);
    tag('span',
        classes: 'file-info', contents: issue.span.sourceUrl.toString());
    endTag();

    startTag('div', classes: 'blob-wrapper');
    startTag('table');
    startTag('tbody');

    // TODO: Widen the line extracts - +2 on either side.
    // TODO: Highlight error ranges.
    if (issue.span is SourceSpanWithContext) {
      SourceSpanWithContext context = issue.span;
      String text = context.context.trimRight();
      int lineNum = context.start.line;

      for (String line in text.split('\n')) {
        lineNum++;
        startTag('tr');
        tag('td', classes: 'blob-num', contents: lineNum.toString());
        tag('td',
            classes: 'blob-code blob-code-inner',
            contents: HTML_ESCAPE.convert(line));
        endTag();
      }
    }

    startTag('tr', classes: 'row-expandable');
    tag('td', classes: 'blob-num blob-num-expandable');
    tag('td',
        classes: 'blob-code blob-code-expandable',
        contents: HTML_ESCAPE.convert(issue.message));
    endTag();

    endTag();
    endTag();
    endTag();

    endTag();
  }
}

String _pluralize(int count, String item) => count == 1 ? item : '${item}s';

String _comma(int count) {
  String str = '${count}';
  if (str.length <= 3) return str;
  int pos = str.length - 3;
  return str.substring(0, pos) + ',' + str.substring(pos);
}

const String _css = '''
h2 {
  margin-top: 2em;
  padding-bottom: 0.3em;
  font-size: 1.75em;
  line-height: 1.225;
  border-bottom: 1px solid #eee;
}

.error {
  background-color: #bf1515;
}

.counter.error {
  color: #eee;
  text-shadow: none;
}

.warning {
  background-color: #ffe5a7;
}

.counter.warning {
  color: #777;
}

.info {
  background-color: #eee;
}

.file {
  position: relative;
  margin-top: 20px;
  margin-bottom: 15px;
  border: 1px solid #ddd;
  border-radius: 3px;
}

.file-header {
  padding: 5px 10px;
  background-color: #f7f7f7;
  border-bottom: 1px solid #d8d8d8;
  border-top-left-radius: 2px;
  border-top-right-radius: 2px;
}

.file-info {
  font-size: 12px;
  font-family: Consolas, "Liberation Mono", Menlo, Courier, monospace;
}

.blob-wrapper {
  overflow-x: auto;
  overflow-y: hidden;
}

.message-info {
  font-size: 14px;
}

.blob-num {
  width: 1%;
  min-width: 50px;
  white-space: nowrap;
  font-family: Consolas, "Liberation Mono", Menlo, Courier, monospace;
  font-size: 12px;
  line-height: 18px;
  color: rgba(0,0,0,0.3);
  vertical-align: top;
  text-align: right;
  border: solid #eee;
  border-width: 0 1px 0 0;
  cursor: pointer;
  -webkit-user-select: none;
  -moz-user-select: none;
  -ms-user-select: none;
  user-select: none;
  padding-left: 10px;
  padding-right: 10px;
}

.blob-code {
  /*position: relative;*/
  padding-left: 10px;
  padding-right: 10px;
  vertical-align: top;
}

.blob-code-inner {
  font-family: Consolas, "Liberation Mono", Menlo, Courier, monospace;
  font-size: 12px;
  color: #333;
  white-space: pre;
  overflow: visible;
  word-wrap: normal;
}

table {
  border-collapse: collapse;
  border-spacing: 0;
  margin-bottom: 0;
}

.row-expandable {
  border-top: 1px solid #d8d8d8;
  border-bottom-left-radius: 3px;
  border-bottom-right-radius: 3px;
}

.blob-num-expandable, .blob-code-expandable {
  vertical-align: middle;
  font-size: 14px;
  border-color: #d2dff0;
}

.blob-num-hunk, .blob-num-expandable {
  background-color: #edf2f9;
  border-bottom-left-radius: 3px;
}

.blob-code-hunk, .blob-code-expandable {
  padding-top: 4px;
  padding-bottom: 4px;
  background-color: #f4f7fb;
  border-width: 1px 0;
  border-bottom-right-radius: 3px;
}
''';
