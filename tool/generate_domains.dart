import 'dart:io';

import 'model.dart';
import 'utils/split_words.dart';
import 'utils/string_helpers.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;

final DartFormatter _dartFormatter =
    new DartFormatter(lineEnding: Platform.isWindows ? '\r\n' : '\n');

// TODO(xha): lundi
//  - Reprendre le code pour lancer chrome, se connecter en WebSocket.
//  - Binder l'envoie et la lecture du JSON pour forwarder au bonnes targets.
//  - Faire quelques tests avec chrome normal pour l'impression PDF
// Autres idées où ça peut servir:
//  - remplacer le webdriver pour les tests
//  - faire une capture d'écran d'un élément html (exemple, un label)
//  - capture les requêtes https pour rajouter ces infos dans le résumé des tests.
main() {
  Protocol readProtocol(String fileName) {
    return new Protocol.fromString(
        new File.fromUri(Platform.script.resolve(fileName)).readAsStringSync());
  }

  Directory targetDir =
      new Directory.fromUri(Platform.script.resolve('../lib/domains'));
  if (targetDir.existsSync()) {
    targetDir.deleteSync(recursive: true);
  }
  targetDir.createSync();

  for (Domain domain in [
    readProtocol('browser_protocol.json').domains,
    readProtocol('js_protocol.json').domains
  ].expand((f) => f)) {
    String domainName = domain.domain;
    List<ComplexType> types = domain.types;
    List<Command> commandsJson = domain.commands;
    _DomainContext context = new _DomainContext(domain);

    String fileName = '${_underscoreize(domainName)}.dart';

    List<_InternalType> internalTypes =
        types.map((json) => new _InternalType(context, json)).toList();

    List<_Command> commands =
        commandsJson.map((json) => new _Command(context, json)).toList();

    List<_Event> events =
        domain.events.map((e) => new _Event(context, e)).toList();

    StringBuffer code = new StringBuffer();

    code.writeln(_toComment(domain.description));
    code.writeln();

    //TODO(xha): sort imports
    code.writeln("import 'dart:async';");
    code.writeln('// ignore: unused_import');
    code.writeln("import 'package:meta/meta.dart' show required;");
    code.writeln("import '../src/connection.dart';");

    for (String dependency in context.dependencies) {
      String normalizedDep = _underscoreize(dependency);
      code.writeln("import '$normalizedDep.dart' as $normalizedDep;");
    }

    String className = '${domainName}Domain';
    code.writeln('class $className {');
    code.writeln('final Client _client;');
    code.writeln();
    code.writeln('$className(this._client);');
    code.writeln();

    for (_Event event in events) {
      code.writeln(event.code);
      code.writeln();
    }

    for (_Command command in commands) {
      code.writeln(command.code);
    }

    code.writeln('}');

    for (_Event event in events.where((c) => c.complexTypeCode != null)) {
      code.writeln(event.complexTypeCode);
    }

    for (_Command command in commands.where((c) => c.returnTypeCode != null)) {
      code.writeln(command.returnTypeCode);
    }

    for (_InternalType type in internalTypes) {
      code.writeln(type.code);
    }

    try {
      String formattedCode = _dartFormatter.format(code.toString());

      new File(p.join(targetDir.path, fileName))
          .writeAsStringSync(formattedCode);
    } catch (_) {
      print('Error with code\n$code');
      rethrow;
    }
  }
}

_underscoreize(String input) {
  return splitWords(input).map((String part) => part.toLowerCase()).join('_');
}

class _Command {
  final _DomainContext context;
  final Command command;
  String _code;
  _InternalType _returnType;

  _Command(this.context, this.command) {
    String name = command.name;
    List<Parameter> parameters = command.parameters;
    List<Parameter> returns = command.returns;

    StringBuffer code = new StringBuffer();

    //TODO(xha): create a CommentBuilder to simplify and better manage the spacings between groups.
    code.writeln(_toComment(command.description));
    for (Parameter parameter in parameters) {
      String description = parameter.description;
      if (description != null && description.isNotEmpty) {
        code.writeln(_toComment('[${parameter.name}] $description'));
      }
    }
    if (returns.length == 1) {
      String description = returns[0].description;
      if (description != null && description.isNotEmpty) {
        code.writeln(_toComment('Return: ${description}'));
      }
    }

    String returnTypeName;
    if (returns.isNotEmpty) {
      if (returns.length == 1) {
        Parameter firstReturn = returns.first;
        returnTypeName = context.getPropertyType(firstReturn);
      } else {
        returnTypeName = '${firstLetterUpper(name)}Result';
        ComplexType returnJson =
            new ComplexType(id: returnTypeName, properties: returns);
        _returnType =
            new _InternalType(context, returnJson, generateToJson: false);
      }
    }

    code.writeln(
        'Future${returnTypeName != null ? '<$returnTypeName>':''} $name(');
    List<Parameter> optionals = parameters.where((p) => p.optional).toList();
    List<Parameter> requireds =
        parameters.where((p) => !optionals.contains(p)).toList();

    for (Parameter parameter in requireds) {
      code.writeln(
          '${context.getPropertyType(parameter)} ${parameter.normalizedName}, ');
    }
    if (optionals.isNotEmpty) {
      code.writeln('{');
      for (Parameter parameter in optionals) {
        code.writeln(
            '${context.getPropertyType(parameter)} ${parameter.normalizedName}, ');
      }
      code.writeln('}');
    }
    code.writeln(') async {');

    if (parameters.isNotEmpty) {
      code.writeln('Map parameters = {');
      for (Parameter parameter in requireds) {
        code.writeln("'${parameter.name}' : ${_toJsonCode(parameter)},");
      }
      code.writeln('};');

      for (Parameter parameter in optionals) {
        code.writeln('if (${parameter.normalizedName} != null) {');
        code.writeln(
            "parameters['${parameter.name}'] = ${_toJsonCode(parameter)};");
        code.writeln('}');
      }
    }

    String sendCode = " await _client.send('${context.domain.domain}.$name'";
    if (parameters.isNotEmpty) {
      sendCode += ', parameters';
    }
    sendCode += ');';

    if (returns.isNotEmpty) {
      sendCode = 'Map result = $sendCode\n';
      if (returns.length == 1) {
        Parameter returnParameter = returns.first;
        if (isRawType(returnTypeName)) {
          sendCode += "return result['${returnParameter.name}'];";
        } else if (returnParameter.type == 'array') {
          Parameter elementParameter = new Parameter(
              name: 'e',
              type: returnParameter.items.type,
              ref: returnParameter.items.ref);
          String paramType = context.getPropertyType(elementParameter);
          String mapCode;
          if (isRawType(paramType)) {
            mapCode = 'e as $paramType';
          } else {
            mapCode =
                'new ${context.getPropertyType(elementParameter)}.fromJson(e)';
          }

          sendCode +=
              "return (result['${returnParameter.name}'] as List).map((e) => $mapCode).toList();";
        } else {
          sendCode +=
              "return new $returnTypeName.fromJson(result['${returnParameter.name}']);";
        }
      } else {
        sendCode += 'return new $returnTypeName.fromJson(result);';
      }
    }

    code.writeln(sendCode);

    code.writeln('}');

    _code = code.toString();
  }

  String get code => _code;

  String get returnTypeCode => _returnType?.code;
}

class _Event {
  final _DomainContext context;
  final Event event;
  String _code;
  _InternalType _complexType;

  _Event(this.context, this.event) {
    String name = event.name;
    List<Parameter> parameters = event.parameters;

    StringBuffer code = new StringBuffer();

    String streamTypeName;
    if (parameters.isNotEmpty) {
      if (parameters.length == 1) {
        Parameter firstReturn = parameters.first;
        streamTypeName = context.getPropertyType(firstReturn);
      } else {
        streamTypeName = '${firstLetterUpper(name)}Event';
        ComplexType returnJson =
            new ComplexType(id: streamTypeName, properties: parameters);
        _complexType =
            new _InternalType(context, returnJson, generateToJson: false);
      }
    }

    //TODO(xha): create a CommentBuilder to simplify and better manage the spacings between groups.
    code.writeln(_toComment(event.description));

    String streamName = 'on${firstLetterUpper(name)}';
    code.writeln(
        'Stream${streamTypeName != null ? '<$streamTypeName>':''} get $streamName => '
        "_client.onEvent.where((Event event) => event.name == '${context.domain.domain}.$name')");

    if (parameters.isNotEmpty) {
      String mapCode;
      if (parameters.length == 1) {
        Parameter parameter = parameters.first;
        if (isRawType(streamTypeName)) {
          mapCode = "event.parameters['${parameter.name}'] as $streamTypeName";
        } else if (parameter.type == 'array') {
          Parameter elementParameter = new Parameter(
              name: 'e', type: parameter.items.type, ref: parameter.items.ref);
          String paramType = context.getPropertyType(elementParameter);
          String insideCode;
          if (isRawType(paramType)) {
            insideCode = 'e as $paramType';
          } else {
            insideCode =
                'new ${context.getPropertyType(elementParameter)}.fromJson(e)';
          }

          mapCode =
              "(event.parameters['${parameter.name}'] as List).map((e) => $insideCode).toList()";
        } else {
          mapCode = "new $streamTypeName.fromJson(event.parameters['${parameter.name}'])";
        }
      } else {
        mapCode = 'new $streamTypeName.fromJson(event.parameters)';
      }
      assert(mapCode != null);
      code.writeln('.map((Event event) => $mapCode)');
    }

    code.writeln(';');

    _code = code.toString();
  }

  String get code => _code;

  String get complexTypeCode => _complexType?.code;
}

String _toJsonCode(Parameter parameter) {
  String name = parameter.name;
  String type = parameter.type;

  if (type != null &&
      const ['string', 'boolean', 'number', 'integer', 'object']
          .contains(type)) {
    return name;
  } else if (type == 'array') {
    Parameter elementParameter = new Parameter(
        name: 'e', type: parameter.items.type, ref: parameter.items.ref);
    return '$name.map((e) => ${_toJsonCode(elementParameter)}).toList()';
  }
  return '$name.toJson()';
}

class _InternalType {
  final _DomainContext context;
  final ComplexType type;
  final bool generateToJson;
  String _code;

  _InternalType(this.context, this.type, {this.generateToJson: true}) {
    String id = type.id;

    StringBuffer code = new StringBuffer();

    code.writeln(_toComment(type.description));
    code.writeln('class $id {');

    List<Parameter> properties = [];
    List<Parameter> jsonProperties = type.properties;
    bool hasProperties = jsonProperties.isNotEmpty;
    List<String> enumValues = type.enums;
    bool isEnum = false;
    if (hasProperties) {
      properties.addAll(jsonProperties);
    } else {
      properties.add(
          new Parameter(name: 'value', type: type.type, items: type.items));

      if (enumValues != null) {
        isEnum = true;
        for (String enumValue in enumValues) {
          String normalizedValue = _normalizeEnumValue(enumValue);

          code.writeln(
              "static const $id $normalizedValue = const $id._('$enumValue');");
        }

        code.writeln('static const values = const {');
        for (String enumValue in enumValues) {
          String normalizedValue = _normalizeEnumValue(enumValue);
          code.writeln("'$enumValue': $normalizedValue,");
        }
        code.writeln('};');
      }
    }

    for (Parameter property in properties) {
      code.writeln(_toComment(property.description));
      code.writeln(
          'final ${context.getPropertyType(property)} ${property.normalizedName};');
      code.writeln('');
    }

    List<Parameter> optionals = properties.where((p) => p.optional).toList();
    List<Parameter> requireds =
        properties.where((p) => !optionals.contains(p)).toList();

    if (hasProperties) {
      code.writeln('$id({');
      for (Parameter property in properties) {
        bool isOptional = property.optional;
        code.writeln(
            '${!isOptional ? '@required ' : ''}this.${property.normalizedName},');
      }
      code.writeln('});');
    } else if (isEnum) {
      code.writeln('const $id._(this.value);');
    } else {
      code.writeln('$id(this.value);');
    }

    code.writeln();
    if (hasProperties) {
      code.writeln('factory $id.fromJson(Map json) {');
      code.writeln('return new $id(');
      for (Parameter property in properties) {
        String propertyName = property.name;
        String instantiateCode =
            _fromJsonCode(property, "json['$propertyName']");
        if (property.optional) {
          instantiateCode =
              "json.containsKey('$propertyName') ? $instantiateCode : null";
        }

        code.writeln("${property.normalizedName}:  $instantiateCode,");
      }
      code.writeln(');');
      code.writeln('}');
    } else if (isEnum) {
      code.writeln('factory $id.fromJson(String value) => values[value];');
    } else {
      code.writeln(
          'factory $id.fromJson(${context.getPropertyType(properties.first)} value) => new $id(value);');
    }

    //TODO(xha): only generate toJson when the type is actually going to be serialized.
    // And only generate fromJson when the type is actually un-serialized
    if (generateToJson) {
      code.writeln('');
      if (hasProperties) {
        code.writeln('Map toJson() {');
        code.writeln('Map json = {');
        for (Parameter property in requireds) {
          code.writeln("'${property.name}': ${_toJsonCode(property)},");
        }
        code.writeln('};');
        for (Parameter property in optionals) {
          code.writeln('if (${property.normalizedName} != null) {');
          code.writeln("json['${property.name}'] = ${_toJsonCode(property)};");
          code.writeln('}');
        }
        code.writeln('return json;');
        code.writeln('}');
      } else {
        code.writeln(
            '${context.getPropertyType(properties.first)} toJson() => value;');
      }
    }

    if (!hasProperties) {
      //TODO(xha): generate operator== and hashcode also for complex type?
      code.writeln();
      code.writeln('bool operator ==(other) => other is $id && other.value == value;');
      code.writeln();
      code.writeln('int get hashCode => value.hashCode;');
    }

    //TODO(xha): generate a readable toString() method.

    code.writeln('}');

    _code = code.toString();
  }

  static String _normalizeEnumValue(String input) {
    input = _sanitizeName(input);
    String normalizedValue = splitWords(input).map(firstLetterUpper).join('');
    normalizedValue = firstLetterLower(normalizedValue);
    normalizedValue = preventKeywords(normalizedValue);

    return normalizedValue;
  }

  String _fromJsonCode(Parameter parameter, String jsonParameter,
      {bool withAs: false}) {
    String type = parameter.type;

    if (type != null &&
        const ['string', 'boolean', 'number', 'integer', 'object', 'any']
            .contains(type)) {
      if (withAs) {
        return '$jsonParameter as ${context.getPropertyType(parameter)}';
      } else {
        return jsonParameter;
      }
    } else if (type == 'array') {
      Parameter elementParameter = new Parameter(
          name: 'e', type: parameter.items.type, ref: parameter.items.ref);
      return "($jsonParameter as List).map((e) => ${_fromJsonCode(elementParameter, 'e', withAs: true)}).toList()";
    }
    return "new ${context.getPropertyType(parameter)}.fromJson($jsonParameter)";
  }

  String get code => _code;
}

class _DomainContext {
  final Domain domain;
  final Set<String> dependencies = new Set();

  _DomainContext(this.domain);

  String getPropertyType(Typed parameter) {
    String type = parameter.type;

    if (type == null) {
      type = parameter.ref;
      assert(type != null);

      if (type.contains('.')) {
        List<String> typeAndDomain = type.split('.');
        String domain = typeAndDomain[0];
        dependencies.add(domain);

        return '${_underscoreize(domain)}.${typeAndDomain[1]}';
      }
    }

    if (type == 'integer') return 'int';
    if (type == 'number') return 'num';
    if (type == 'string') return 'String';
    if (type == 'boolean') return 'bool';
    if (type == 'any') return 'dynamic';
    if (type == 'object') return 'Map';
    if (type == 'array') {
      if (parameter is Parameter) {
        ListItems items = parameter.items;
        String innerType = getPropertyType(items);

        return 'List<$innerType>';
      } else {
        assert(false);
      }
    }

    return type;
  }
}

bool isRawType(String type) =>
    const ['int', 'num', 'String', 'bool', 'dynamic', 'Map'].contains(type);

String _toComment(String comment) {
  if (comment != null && comment.isNotEmpty) {
    //TODO(xha): handle multi-lines comments and auto-split after 80 characters
    return '/// $comment';
  } else {
    return '';
  }
}

String _sanitizeName(String input) {
  if (input == '-0') {
    return 'minusZero';
  } else if (input == '-Infinity') {
    return 'minusInfinity';
  }
  return input;
}