// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dev_compiler.src.html_gen;

class HtmlGen {
  final StringBuffer _buffer = new StringBuffer();
  bool _startOfLine = true;
  final List<String> _tags = [];
  final List<bool> _indents = [];
  String _indent = '';

  HtmlGen() {
    _init();
  }

  void _init() {
    writeln('<!DOCTYPE html>');
    writeln();
    writeln('<!-- generated by dev_compiler -->');
    writeln();
  }

  void start(
      {String title,
      String cssRef,
      String theme,
      String jsScript,
      String inlineStyle}) {
    startTag('html', newLine: false);
    writeln();
    startTag('head');
    writeln('<meta charset="utf-8">');
    writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">');
    if (title != null) {
      writeln('<title>${title}</title>');
    }
    if (cssRef != null) {
      writeln('<link href="${cssRef}" rel="stylesheet" media="screen">');
    }
    if (theme != null) {
      writeln('<link href="${theme}" rel="stylesheet">');
    }
    if (jsScript != null) {
      writeln('<script src="${jsScript}"></script>');
    }
    if (inlineStyle != null) {
      startTag('style');
      writeln(inlineStyle);
      endTag();
    }
    endTag();
    writeln();
    startTag('body', newLine: false);
    writeln();
  }

  void startTag(String tag,
      {String attributes, String classes, bool newLine: true}) {
    if (classes != null && classes.isNotEmpty) {
      if (attributes == null) {
        attributes = 'class="${classes}"';
      } else {
        attributes += ' class="${classes}"';
      }
    }

    if (attributes != null) {
      if (newLine) {
        writeln('<${tag} ${attributes}>');
      } else {
        write('<${tag} ${attributes}>');
      }
    } else {
      if (newLine) {
        writeln('<${tag}>');
      } else {
        write('<${tag}>');
      }
    }
    _indents.add(newLine);
    if (newLine) {
      _indent = '$_indent\t';
    }
    _tags.add(tag);
  }

  void tag(String tag,
      {String contents, String classes, String href, String attributes}) {
    if (attributes == null) attributes = '';
    if (contents == null) contents = '';

    if (classes != null && classes.isNotEmpty) attributes +=
        ' class="${classes}"';
    if (href != null) attributes += ' href="${href}"';

    if (attributes.isNotEmpty) attributes = ' ' + attributes.trim();

    writeln('<$tag$attributes>$contents</$tag>');
  }

  void endTag() {
    String tag = _tags.removeLast();
    bool wasIndent = _indents.removeLast();
    if (wasIndent) {
      _indent = _indent.substring(0, _indent.length - 1);
    }
    writeln('</${tag}>');
  }

  void end() {
    // body
    endTag();
    // html
    endTag();
  }

  String toString() => _buffer.toString();

  void reset() {
    _buffer.clear();
    _startOfLine = true;
    _tags.clear();
    _indents.clear();
    _indent = '';

    _init();
  }

  void write(String str) {
    if (_startOfLine) {
      _buffer.write(_indent);
      _startOfLine = false;
    }
    _buffer.write(str);
  }

  void writeln([String str]) {
    if (str == null) {
      write('\n');
    } else {
      write('${str}\n');
    }
    _startOfLine = true;
  }
}
