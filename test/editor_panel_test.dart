import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:courier_flutter/widgets/editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  testWidgets('切换标签会取消原文档的自动保存计时器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    await settings.load();
    await settings.setAutoSave(true);
    await settings.setAutoSaveDelaySeconds(1);

    final firstDocument = EditorDocument(
      id: 'first',
      path: 'first.md',
      relativePath: 'first.md',
      fileName: 'first.md',
      content: 'first original',
      savedContent: 'first original',
    );
    final secondDocument = EditorDocument(
      id: 'second',
      path: 'second.md',
      relativePath: 'second.md',
      fileName: 'second.md',
      content: 'second original',
      savedContent: 'second original',
    );
    final workspace = _RecordingWorkspaceService([
      firstDocument,
      secondDocument,
    ]);
    addTearDown(() {
      workspace.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: EditorPanel())),
      ),
    );

    await tester.enterText(find.byType(TextField), 'first changed');
    secondDocument.updateContent('second dirty');
    workspace.setActiveDocument(secondDocument.id);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    expect(workspace.savedDocumentIds, isEmpty);
    expect(secondDocument.isDirty, isTrue);
  });
}

class _RecordingWorkspaceService extends WorkspaceService {
  final List<EditorDocument> _testDocuments;
  final List<String> savedDocumentIds = [];
  String? _testActiveDocumentId;

  _RecordingWorkspaceService(this._testDocuments)
    : _testActiveDocumentId = _testDocuments.first.id,
      super(
        fileSystem: SafeFileSystem(),
        configService: WorkspaceConfigService(logger: AppLogger()),
        logger: AppLogger(),
      ) {
    for (final document in _testDocuments) {
      document.addListener(notifyListeners);
    }
  }

  @override
  List<EditorDocument> get documents => List.unmodifiable(_testDocuments);

  @override
  String? get activeDocumentId => _testActiveDocumentId;

  @override
  EditorDocument? get activeDocument => _testDocuments
      .where((document) => document.id == _testActiveDocumentId)
      .firstOrNull;

  @override
  void setActiveDocument(String documentId) {
    if (_testDocuments.any((document) => document.id == documentId)) {
      _testActiveDocumentId = documentId;
      notifyListeners();
    }
  }

  @override
  Future<void> saveDocument(String documentId, {bool force = false}) async {
    savedDocumentIds.add(documentId);
  }

  @override
  void dispose() {
    for (final document in _testDocuments) {
      document.removeListener(notifyListeners);
      document.dispose();
    }
    super.dispose();
  }
}
