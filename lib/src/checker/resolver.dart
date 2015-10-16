// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Encapsulates how to invoke the analyzer resolver and overrides how it
/// computes types on expressions to use our restricted set of types.
library dev_compiler.src.checker.resolver;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart' show Source;
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/generated/static_type_analyzer.dart';
import 'package:analyzer/src/generated/utilities_collection.dart'
    show DirectedGraph;
import 'package:logging/logging.dart' as logger;

import '../../strong_mode.dart' show StrongModeOptions;
import '../utils.dart';
import 'rules.dart';

final _log = new logger.Logger('dev_compiler.src.resolver');

/// A [LibraryResolver] that performs inference on top-levels and fields based
/// on the value of the initializer, and on fields and methods based on
/// overridden members in super classes.
class LibraryResolverWithInference extends LibraryResolver {
  final StrongModeOptions _options;

  LibraryResolverWithInference(context, this._options) : super(context);

  @override
  void resolveReferencesAndTypes() {
    _resolveVariableReferences();

    // Run resolution in two stages, skipping method bodies first, so we can run
    // type-inference before we fully analyze methods.
    var visitors = _createVisitors();
    _resolveEverything(visitors);
    _runInference(visitors);

    visitors.values.forEach((v) => v.skipMethodBodies = false);
    _resolveEverything(visitors);
  }

  // Note: this was split from _resolveReferencesAndTypesInLibrary so we do it
  // only once.
  void _resolveVariableReferences() {
    for (Library library in resolvedLibraries) {
      for (Source source in library.compilationUnitSources) {
        library.getAST(source).accept(new VariableResolverVisitor(
            library.libraryElement, source, typeProvider, library.errorListener,
            nameScope: library.libraryScope));
      }
    }
  }

  // Note: this was split from _resolveReferencesAndTypesInLibrary so we can do
  // resolution in pieces.
  Map<Source, RestrictedResolverVisitor> _createVisitors() {
    var visitors = <Source, RestrictedResolverVisitor>{};
    for (Library library in resolvedLibraries) {
      for (Source source in library.compilationUnitSources) {
        var visitor = new RestrictedResolverVisitor(
            library, source, typeProvider, _options);
        visitors[source] = visitor;
      }
    }
    return visitors;
  }

  /// Runs the resolver on the entire library cycle.
  void _resolveEverything(Map<Source, RestrictedResolverVisitor> visitors) {
    for (Library library in resolvedLibraries) {
      for (Source source in library.compilationUnitSources) {
        library.getAST(source).accept(visitors[source]);
      }
    }
  }

  _runInference(Map<Source, RestrictedResolverVisitor> visitors) {
    var globalsAndStatics = <VariableDeclaration>[];
    var classes = <ClassDeclaration>[];

    // Extract top-level members that are const, statics, or classes.
    for (Library library in resolvedLibraries) {
      for (Source source in library.compilationUnitSources) {
        CompilationUnit ast = library.getAST(source);
        for (var declaration in ast.declarations) {
          if (declaration is TopLevelVariableDeclaration) {
            globalsAndStatics.addAll(declaration.variables.variables);
          } else if (declaration is ClassDeclaration) {
            classes.add(declaration);
            for (var member in declaration.members) {
              if (member is FieldDeclaration &&
                  (member.fields.isConst || member.isStatic)) {
                globalsAndStatics.addAll(member.fields.variables);
              }
            }
          }
        }
      }
    }
    _inferGlobalsAndStatics(globalsAndStatics, visitors);
    _inferInstanceFields(classes, visitors);
  }

  _inferGlobalsAndStatics(List<VariableDeclaration> globalsAndStatics,
      Map<Source, RestrictedResolverVisitor> visitors) {
    var elementToDeclaration = {};
    for (var c in globalsAndStatics) {
      elementToDeclaration[c.element] = c;
    }
    var constGraph = new DirectedGraph<VariableDeclaration>();
    globalsAndStatics.forEach(constGraph.addNode);
    for (var c in globalsAndStatics) {
      for (var e in _VarExtractor.extract(c.initializer)) {
        // Note: declaration is null for variables that come from other strongly
        // connected components.
        var declaration = elementToDeclaration[e];
        if (declaration != null) constGraph.addEdge(c, declaration);
      }
    }

    for (var component in constGraph.computeTopologicalSort()) {
      component.forEach((v) => _reanalyzeVar(visitors, v));
      _inferVariableFromInitializer(component);
    }
  }

  _inferInstanceFields(List<ClassDeclaration> classes,
      Map<Source, RestrictedResolverVisitor> visitors) {
    // First propagate what was inferred from globals to all instance fields.

    // TODO(sigmund): also do a fine-grain propagation between fields. We want
    // infer-by-override to take precedence, so we would have to include
    // classes in the dependency graph and ensure that fields depend on their
    // class, and classes depend on superclasses.
    classes
        .expand((c) => c.members.where(_isInstanceField))
        .expand((f) => f.fields.variables)
        .forEach((v) => _reanalyzeVar(visitors, v));

    // Track types in this strongly connected component, ensure we visit
    // supertypes before subtypes.
    var typeToDeclaration = <InterfaceType, ClassDeclaration>{};
    classes.forEach((c) => typeToDeclaration[c.element.type] = c);
    var seen = new Set<InterfaceType>();
    visit(ClassDeclaration cls) {
      var element = cls.element;
      var type = element.type;
      if (seen.contains(type)) return;
      seen.add(type);
      for (var supertype in element.allSupertypes) {
        var supertypeClass = typeToDeclaration[supertype];
        if (supertypeClass != null) visit(supertypeClass);
      }

      // Infer field types from overrides first, otherwise from initializers.
      var pending = new Set<VariableDeclaration>();
      cls.members
          .where(_isInstanceField)
          .forEach((f) => _inferFieldTypeFromOverride(f, pending));
      if (pending.isNotEmpty) _inferVariableFromInitializer(pending);

      // Infer return-types and param-types from overrides
      cls.members
          .where((m) => m is MethodDeclaration && !m.isStatic)
          .forEach(_inferMethodTypesFromOverride);
    }
    classes.forEach(visit);
  }

  void _reanalyzeVar(Map<Source, RestrictedResolverVisitor> visitors,
      VariableDeclaration variable) {
    if (variable.initializer == null) return;
    var visitor = visitors[(variable.root as CompilationUnit).element.source];
    visitor.reanalyzeInitializer(variable);
  }

  static bool _isInstanceField(f) =>
      f is FieldDeclaration && !f.isStatic && !f.fields.isConst;

  /// Attempts to infer the type on [field] from overridden fields or getters if
  /// a type was not specified. If no type could be inferred, but it contains an
  /// initializer, we add it to [pending] so we can try to infer it using the
  /// initializer type instead.
  void _inferFieldTypeFromOverride(
      FieldDeclaration field, Set<VariableDeclaration> pending) {
    var variables = field.fields;
    for (var variable in variables.variables) {
      var varElement = variable.element as FieldElement;
      if (!varElement.type.isDynamic || variables.type != null) continue;
      var getter = varElement.getter;
      // Note: type will be null only when there are no overrides. When some
      // override's type was not specified and couldn't be inferred, the type
      // here will be dynamic.
      var enclosingElement = varElement.enclosingElement;
      var type = searchTypeFor(enclosingElement.type, getter);

      // Infer from the RHS when there are no overrides.
      if (type == null) {
        if (variable.initializer != null) pending.add(variable);
        continue;
      }

      // When field is final and overridden getter is dynamic, we can infer from
      // the RHS without breaking subtyping rules (return type is covariant).
      if (type.returnType.isDynamic) {
        if (variables.isFinal && variable.initializer != null) {
          pending.add(variable);
        }
        continue;
      }

      // Use type from the override.
      var newType = type.returnType;
      varElement.type = newType;
      varElement.getter.returnType = newType;
      if (!varElement.isFinal) varElement.setter.parameters[0].type = newType;
    }
  }

  void _inferMethodTypesFromOverride(MethodDeclaration method) {
    var methodElement = method.element;
    if (methodElement is! MethodElement &&
        methodElement is! PropertyAccessorElement) return;

    var enclosingElement = methodElement.enclosingElement as ClassElement;
    FunctionType type = null;

    // Infer the return type if omitted
    if (methodElement.returnType.isDynamic && method.returnType == null) {
      type = searchTypeFor(enclosingElement.type, methodElement);
      if (type == null) return;
      if (!type.returnType.isDynamic) {
        methodElement.returnType = type.returnType;
      }
    }

    // Infer parameter types if omitted
    if (method.parameters == null) return;
    var parameters = method.parameters.parameters;
    var length = parameters.length;
    for (int i = 0; i < length; ++i) {
      var parameter = parameters[i];
      if (parameter is DefaultFormalParameter) parameter = parameter.parameter;
      if (parameter is SimpleFormalParameter && parameter.type == null) {
        type = type ?? searchTypeFor(enclosingElement.type, methodElement);
        if (type == null) return;
        if (type.parameters.length > i && !type.parameters[i].type.isDynamic) {
          parameter.element.type = type.parameters[i].type;
        }
      }
    }
  }

  void _inferVariableFromInitializer(Iterable<VariableDeclaration> variables) {
    for (var variable in variables) {
      var declaration = variable.parent as VariableDeclarationList;
      // Only infer on variables that don't have any declared type.
      if (declaration.type != null) continue;
      var initializer = variable.initializer;
      if (initializer == null) continue;
      var type = initializer.staticType;
      if (type == null || type.isDynamic || type.isBottom) continue;
      var element = variable.element as PropertyInducingElement;
      // Note: it's ok to update the type here, since initializer.staticType
      // is already computed for all declarations in the library cycle. The
      // new types will only be propagated on a second run of the
      // ResolverVisitor.
      element.type = type;
      element.getter.returnType = type;
      if (!element.isFinal && !element.isConst) {
        element.setter.parameters[0].type = type;
      }
    }
  }
}

/// Extracts the [VariableElement]s used in an initializer expression.
class _VarExtractor extends RecursiveAstVisitor {
  final elements = <VariableElement>[];
  visitSimpleIdentifier(SimpleIdentifier node) {
    var e = node.staticElement;
    if (e is PropertyAccessorElement) elements.add(e.variable);
  }

  static List<VariableElement> extract(Expression initializer) {
    if (initializer == null) return const [];
    var extractor = new _VarExtractor();
    initializer.accept(extractor);
    return extractor.elements;
  }
}

/// Overrides the default [ResolverVisitor] to support type inference in
/// [LibraryResolverWithInference] above.
///
/// Before inference, this visitor is used to resolve top-levels, classes, and
/// fields, but nothing within method bodies. After inference, this visitor is
/// used again to step into method bodies and complete resolution as a second
/// phase.
class RestrictedResolverVisitor extends ResolverVisitor {
  final TypeProvider _typeProvider;

  /// Whether to skip resolution within method bodies.
  bool skipMethodBodies = true;

  /// State of the resolver at the point a field or variable was declared.
  final _stateAtDeclaration = <AstNode, _ResolverState>{};

  /// Internal tracking of whether a node was skipped while visiting, for
  /// example, if it contained a function expression with a function body.
  bool _nodeWasSkipped = false;

  /// Internal state, whether we are revisiting an initializer, so we minimize
  /// the work being done elsewhere.
  bool _revisiting = false;

  /// Initializers that have been visited, reanalyzed, and for which no node was
  /// internally skipped. These initializers are fully resolved and don't need
  /// to be re-resolved on a sunsequent pass.
  final _visitedInitializers = new Set<VariableDeclaration>();

  RestrictedResolverVisitor(Library library, Source source,
      TypeProvider typeProvider, StrongModeOptions options)
      : _typeProvider = typeProvider,
        super(
            library.libraryElement, source, typeProvider, library.errorListener,
            nameScope: library.libraryScope,
            inheritanceManager: library.inheritanceManager,
            typeAnalyzerFactory: RestrictedStaticTypeAnalyzer.constructor);

  reanalyzeInitializer(VariableDeclaration variable) {
    try {
      _revisiting = true;
      _nodeWasSkipped = false;
      var node = variable.parent.parent;
      var oldState;
      var state = _stateAtDeclaration[node];
      if (state != null) {
        oldState = new _ResolverState(this);
        state.restore(this);
        if (node is FieldDeclaration) {
          var cls = node.parent as ClassDeclaration;
          enclosingClass = cls.element;
        }
      }
      visitNode(variable.initializer);
      if (!_nodeWasSkipped) _visitedInitializers.add(variable);
      if (oldState != null) oldState.restore(this);
    } finally {
      _revisiting = false;
    }
  }

  @override
  Object visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    _stateAtDeclaration[node] = new _ResolverState(this);
    return super.visitTopLevelVariableDeclaration(node);
  }

  @override
  Object visitFieldDeclaration(FieldDeclaration node) {
    _stateAtDeclaration[node] = new _ResolverState(this);
    return super.visitFieldDeclaration(node);
  }

  Object visitVariableDeclaration(VariableDeclaration node) {
    var state = new _ResolverState(this);
    try {
      if (_revisiting) {
        _stateAtDeclaration[node].restore(this);
      } else {
        _stateAtDeclaration[node] = state;
      }
      return super.visitVariableDeclaration(node);
    } finally {
      state.restore(this);
    }
  }

  @override
  Object visitNode(AstNode node) {
    if (skipMethodBodies && node is FunctionBody) {
      _nodeWasSkipped = true;
      return null;
    }
    if (_visitedInitializers.contains(node)) return null;
    assert(node is! Statement || !skipMethodBodies);
    return super.visitNode(node);
  }

  @override
  Object visitMethodDeclaration(MethodDeclaration node) {
    if (skipMethodBodies) {
      node.accept(elementResolver);
      node.accept(typeAnalyzer);
      return null;
    } else {
      return super.visitMethodDeclaration(node);
    }
  }

  @override
  Object visitFunctionDeclaration(FunctionDeclaration node) {
    if (skipMethodBodies) {
      node.accept(elementResolver);
      node.accept(typeAnalyzer);
      return null;
    } else {
      return super.visitFunctionDeclaration(node);
    }
  }

  @override
  Object visitConstructorDeclaration(ConstructorDeclaration node) {
    if (skipMethodBodies) {
      node.accept(elementResolver);
      node.accept(typeAnalyzer);
      return null;
    } else {
      return super.visitConstructorDeclaration(node);
    }
  }

  @override
  visitFieldFormalParameter(FieldFormalParameter node) {
    // Ensure the field formal parameter's type is updated after inference.
    // Normally this happens during TypeResolver, but that's before we've done
    // inference on the field type.
    var element = node.element;
    if (element is FieldFormalParameterElement) {
      if (element.type.isDynamic) {
        // In malformed code, there may be no actual field.
        if (element.field != null) {
          element.type = element.field.type;
        }
      }
    }
    super.visitFieldFormalParameter(node);
  }
}

/// Internal state of the resolver, stored so we can reanalyze portions of the
/// AST quickly, without recomputing everything from the top.
class _ResolverState {
  final TypePromotionManager_TypePromoteScope promotionScope;
  final TypeOverrideManager_TypeOverrideScope overrideScope;
  final Scope nameScope;

  _ResolverState(ResolverVisitor visitor)
      : promotionScope = visitor.promoteManager.currentScope,
        overrideScope = visitor.overrideManager.currentScope,
        nameScope = visitor.nameScope;

  void restore(ResolverVisitor visitor) {
    visitor.promoteManager.currentScope = promotionScope;
    visitor.overrideManager.currentScope = overrideScope;
    visitor.nameScope = nameScope;
  }
}

/// Overrides the default [StaticTypeAnalyzer] to adjust rules that are stricter
/// in the restricted type system and to infer types for untyped local
/// variables.
class RestrictedStaticTypeAnalyzer extends StaticTypeAnalyzer {
  final TypeProvider _typeProvider;
  Map<String, DartType> _objectMembers;

  RestrictedStaticTypeAnalyzer(ResolverVisitor r)
      : _typeProvider = r.typeProvider,
        super(r) {
    _objectMembers = getObjectMemberMap(_typeProvider);
  }

  static constructor(ResolverVisitor r) => new RestrictedStaticTypeAnalyzer(r);

  @override // to infer type from initializers
  visitVariableDeclaration(VariableDeclaration node) {
    _inferType(node);
    return super.visitVariableDeclaration(node);
  }

  /// Infer the type of a variable based on the initializer's type.
  void _inferType(VariableDeclaration node) {
    var initializer = node.initializer;
    if (initializer == null) return;

    var declaredType = (node.parent as VariableDeclarationList).type;
    if (declaredType != null) return;
    var element = node.element;
    if (element is! LocalVariableElement) return;
    if (element.type != _typeProvider.dynamicType) return;

    var type = initializer.staticType;
    if (type == null || type == _typeProvider.bottomType) return;
    element.type = type;
    if (element is PropertyInducingElement) {
      element.getter.returnType = type;
      if (!element.isFinal && !element.isConst) {
        element.setter.parameters[0].type = type;
      }
    }
  }

  // TODO(vsm): Use leafp's matchType here?
  DartType _findIteratedType(InterfaceType type) {
    if (type.element == _typeProvider.iterableType.element) {
      var typeArguments = type.typeArguments;
      assert(typeArguments.length == 1);
      return typeArguments[0];
    }

    if (type == _typeProvider.objectType) return null;

    var result = _findIteratedType(type.superclass);
    if (result != null) return result;

    for (final parent in type.interfaces) {
      result = _findIteratedType(parent);
      if (result != null) return result;
    }

    for (final parent in type.mixins) {
      result = _findIteratedType(parent);
      if (result != null) return result;
    }

    return null;
  }

  @override
  visitDeclaredIdentifier(DeclaredIdentifier node) {
    super.visitDeclaredIdentifier(node);
    if (node.type != null) return;

    var parent = node.parent as ForEachStatement;
    var expr = parent.iterable;
    var element = node.element as LocalVariableElementImpl;
    var exprType = expr.staticType;
    if (exprType is InterfaceType) {
      var iteratedType = _findIteratedType(exprType);
      if (iteratedType != null) {
        element.type = iteratedType;
      }
    }
  }

  bool _isSealed(DartType t) {
    return _typeProvider.nonSubtypableTypes.contains(t);
  }

  List<List> _genericList = null;

  DartType _matchGeneric(MethodInvocation node, Element element) {
    var e = node.methodName.staticElement;

    if (_genericList == null) {
      var minmax = (DartType tx, DartType ty) => (tx == ty &&
              (tx == _typeProvider.intType || tx == _typeProvider.doubleType))
          ? tx
          : null;

      var map = (DartType tx) => (tx is FunctionType)
          ? _typeProvider.iterableType.substitute4([tx.returnType])
          : null;

      // TODO(vsm): LUB?
      var fold = (DartType tx, DartType ty) =>
          (ty is FunctionType && tx == ty.returnType) ? tx : null;

      // TODO(vsm): Flatten?
      var then = (DartType tx) => (tx is FunctionType)
          ? _typeProvider.futureType.substitute4([tx.returnType])
          : null;

      var wait = (DartType tx) {
        // Iterable<Future<T>> -> Future<List<T>>
        var futureType = _findIteratedType(tx);
        if (futureType.element.type != _typeProvider.futureType) return null;
        var typeArguments = futureType.typeArguments;
        if (typeArguments.length != 1) return null;
        var baseType = typeArguments[0];
        if (baseType.isDynamic) return null;
        return _typeProvider.futureType.substitute4([
          _typeProvider.listType.substitute4([baseType])
        ]);
      };

      _genericList = [
        // Top-level methods
        ['dart:math', 'max', 2, minmax],
        ['dart:math', 'min', 2, minmax],
        // Static methods
        [_typeProvider.futureType, 'wait', 1, wait],
        // Instance methods
        [_typeProvider.iterableDynamicType, 'map', 1, map],
        [_typeProvider.iterableDynamicType, 'fold', 2, fold],
        [_typeProvider.futureDynamicType, 'then', 1, then],
      ];
    }

    var targetType = node.target?.staticType;
    var arguments = node.argumentList.arguments;

    for (var generic in _genericList) {
      if (e?.name == generic[1]) {
        if ((generic[0] is String &&
                element?.library.source.uri.toString() == generic[0]) ||
            (generic[0] is DartType &&
                targetType != null &&
                targetType.isSubtypeOf(generic[0]))) {
          if (arguments.length == generic[2]) {
            return Function.apply(
                generic[3], arguments.map((arg) => arg.staticType).toList());
          }
        }
      }
    }

    return null;
  }

  @override // to propagate types to identifiers
  visitMethodInvocation(MethodInvocation node) {
    // TODO(jmesserly): we rely on having a staticType propagated to the
    // methodName identifier. This shouldn't be necessary for method calls, so
    // analyzer doesn't do it by default. Conceptually what we're doing here
    // is asking for a tear off. We need this until we can fix #132, and rely
    // on `node.staticElement == null` instead of `rules.isDynamicCall(node)`.
    visitSimpleIdentifier(node.methodName);

    super.visitMethodInvocation(node);

    // Search for Object methods.
    var name = node.methodName.name;
    if (node.staticType.isDynamic &&
        _objectMembers.containsKey(name) &&
        isDynamicTarget(node.target)) {
      var type = _objectMembers[name];
      if (type is FunctionType &&
          type.parameters.isEmpty &&
          node.argumentList.arguments.isEmpty) {
        node.methodName.staticType = type;
        // Only infer the type of the overall expression if we have an exact
        // type - e.g., a sealed type.  Otherwise, it may be too strict.
        if (_isSealed(type.returnType)) {
          node.staticType = type.returnType;
        }
      }
    }

    var e = node.methodName.staticElement;
    if (isInlineJS(e)) {
      // Fix types for JS builtin calls.
      //
      // This code was taken from analyzer. It's not super sophisticated:
      // only looks for the type name in dart:core, so we just copy it here.
      //
      // TODO(jmesserly): we'll likely need something that can handle a wider
      // variety of types, especially when we get to JS interop.
      var args = node.argumentList.arguments;
      var first = args.isNotEmpty ? args.first : null;
      if (first is SimpleStringLiteral) {
        var typeStr = first.stringValue;
        if (typeStr == '-dynamic') {
          node.staticType = _typeProvider.bottomType;
        } else {
          var coreLib = _typeProvider.objectType.element.library;
          var classElem = coreLib.getType(typeStr);
          if (classElem != null) {
            var type = fillDynamicTypeArgs(classElem.type, _typeProvider);
            node.staticType = type;
          }
        }
      }
    }

    // Pretend dart:math's min and max are generic:
    //
    //     T min<T extends num>(T x, T y);
    //
    // and infer T. In practice, this just means if the type of x and y are
    // both double or both int, we treat that as the return type.
    //
    // The Dart spec has similar treatment for binary operations on numbers.
    //
    // TODO(jmesserly): remove this when we have a fix for
    // https://github.com/dart-lang/dev_compiler/issues/28
    var inferred = _matchGeneric(node, e);
    // TODO(vsm): If the inferred type is not a subtype, should we use a GLB instead?
    if (inferred != null && inferred.isSubtypeOf(node.staticType)) {
      node.staticType = inferred;
    }
  }

  void _inferObjectAccess(
      Expression node, Expression target, SimpleIdentifier id) {
    // Search for Object accesses.
    var name = id.name;
    if (node.staticType.isDynamic &&
        _objectMembers.containsKey(name) &&
        isDynamicTarget(target)) {
      var type = _objectMembers[name];
      id.staticType = type;
      // Only infer the type of the overall expression if we have an exact
      // type - e.g., a sealed type.  Otherwise, it may be too strict.
      if (_isSealed(type)) {
        node.staticType = type;
      }
    }
  }

  @override
  visitPropertyAccess(PropertyAccess node) {
    super.visitPropertyAccess(node);

    _inferObjectAccess(node, node.target, node.propertyName);
  }

  @override
  visitPrefixedIdentifier(PrefixedIdentifier node) {
    super.visitPrefixedIdentifier(node);

    _inferObjectAccess(node, node.prefix, node.identifier);
  }

  @override
  visitConditionalExpression(ConditionalExpression node) {
    // TODO(vsm): The static type of a conditional should be the LUB of the
    // then and else expressions.  The analyzer appears to compute dynamic when
    // one or the other is the null literal.  Remove this fix once the
    // corresponding analyzer bug is fixed:
    // https://code.google.com/p/dart/issues/detail?id=22854
    super.visitConditionalExpression(node);
    if (node.staticType.isDynamic) {
      var thenExpr = node.thenExpression;
      var elseExpr = node.elseExpression;
      if (thenExpr.staticType.isBottom) {
        node.staticType = elseExpr.staticType;
      } else if (elseExpr.staticType.isBottom) {
        node.staticType = thenExpr.staticType;
      }
    }
  }

  // Review note: no longer need to override visitFunctionExpression, this is
  // handled by the analyzer internally.
  // TODO(vsm): in visitbinaryExpression: check computeStaticReturnType result?
  // TODO(vsm): in visitFunctionDeclaration: Should we ever use the expression
  // type in a (...) => expr or just the written type?

}
