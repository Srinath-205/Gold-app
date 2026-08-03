import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const PsmApp());
}

class PsmApp extends StatefulWidget {
  const PsmApp({super.key, this.repository});

  final FirebaseWorkspaceRepository? repository;

  @override
  State<PsmApp> createState() => _PsmAppState();
}

class _PsmAppState extends State<PsmApp> {
  late final FirebaseWorkspaceRepository _repository;
  List<BusinessAccount> _accounts = <BusinessAccount>[];
  AppUser? _currentUser;
  BusinessAccount? _currentAccount;
  bool _showSplash = true;
  bool _isRestoringSession = true;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirebaseWorkspaceRepository();
    _restoreSession();
    Future<void>.delayed(const Duration(milliseconds: 1100), () {
      if (mounted) {
        setState(() => _showSplash = false);
      }
    });
  }

  Future<void> _restoreSession() async {
    try {
      final session = await _repository.restoreSession();
      if (!mounted) {
        return;
      }
      setState(() {
        _currentUser = session?.user;
        _accounts = session?.accounts ?? <BusinessAccount>[];
        _currentAccount = session == null
            ? null
            : _defaultAccount(session.accounts);
        _isRestoringSession = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isRestoringSession = false);
      }
    }
  }

  Future<void> _login(String email, String password) async {
    final session = await _repository.signIn(email: email, password: password);
    if (!mounted) {
      return;
    }
    setState(() {
      _currentUser = session.user;
      _accounts = session.accounts;
      _currentAccount = _defaultAccount(session.accounts);
    });
  }

  BusinessAccount? _defaultAccount(List<BusinessAccount> accounts) {
    return accounts.length == 1 ? accounts.first : null;
  }

  void _selectAccount(BusinessAccount account) {
    setState(() => _currentAccount = account);
  }

  Future<void> _createFreshAccount() async {
    final currentUser = _currentUser;
    if (currentUser == null) {
      return;
    }

    final nextNumber = _accounts.length + 1;
    final account = BusinessAccount(
      id: 'account_$nextNumber',
      shopName: 'Business Account $nextNumber',
      ownerName: currentUser.name,
      role: UserRole.owner,
      customers: <CustomerProfile>[],
      bills: <BillEntry>[],
      stock: <StockItem>[],
      releases: <ReleaseEntry>[],
      repository: _repository,
    );

    await _repository.createBusinessAccount(
      account: account,
      owner: currentUser,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _accounts.add(account);
      _currentAccount = account;
    });
  }

  void _switchAccount() {
    setState(() => _currentAccount = null);
  }

  void _signOut() {
    _repository.signOut();
    setState(() {
      _currentUser = null;
      _currentAccount = null;
      _accounts = <BusinessAccount>[];
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'P S M Jewellers',
      theme: PsmTheme.light(),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 360),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _buildHome(),
      ),
    );
  }

  Widget _buildHome() {
    if (_showSplash || _isRestoringSession) {
      return const SplashScreen(key: ValueKey<String>('splash'));
    }

    if (_currentUser == null) {
      return LoginScreen(key: const ValueKey<String>('login'), onLogin: _login);
    }

    if (_currentAccount == null) {
      return AccountSwitcherScreen(
        key: const ValueKey<String>('switcher'),
        user: _currentUser!,
        accounts: _accounts,
        onAccountSelected: _selectAccount,
        onCreateFreshAccount: _createFreshAccount,
        onSignOut: _signOut,
      );
    }

    return HomeShell(
      key: ValueKey<String>(_currentAccount!.id),
      user: _currentUser!,
      account: _currentAccount!,
      onSwitchAccount: _switchAccount,
      onSignOut: _signOut,
    );
  }
}

enum UserRole { owner, staff }

extension UserRoleLabel on UserRole {
  String get label {
    switch (this) {
      case UserRole.owner:
        return 'Owner';
      case UserRole.staff:
        return 'Staff';
    }
  }
}

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
  });

  final String id;
  final String name;
  final String email;
  final UserRole role;
}

class SessionData {
  const SessionData({required this.user, required this.accounts});

  final AppUser user;
  final List<BusinessAccount> accounts;
}

class FirebaseWorkspaceException implements Exception {
  const FirebaseWorkspaceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FirebaseWorkspaceRepository {
  FirebaseWorkspaceRepository({
    firebase_auth.FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  }) : _authOverride = auth,
       _firestoreOverride = firestore;

  final firebase_auth.FirebaseAuth? _authOverride;
  final FirebaseFirestore? _firestoreOverride;

  firebase_auth.FirebaseAuth get _auth =>
      _authOverride ?? firebase_auth.FirebaseAuth.instance;

  FirebaseFirestore get _firestore =>
      _firestoreOverride ?? FirebaseFirestore.instance;

  Future<SessionData> signIn({
    required String email,
    required String password,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final credential = await _auth.signInWithEmailAndPassword(
      email: cleanEmail,
      password: password,
    );
    final authUser = credential.user;
    if (authUser == null) {
      throw const FirebaseWorkspaceException('Firebase login failed.');
    }

    return _sessionFromAuthUser(authUser: authUser, email: cleanEmail);
  }

  Future<SessionData?> restoreSession() async {
    final authUser = _auth.currentUser;
    if (authUser == null) {
      return null;
    }

    return _sessionFromAuthUser(
      authUser: authUser,
      email: authUser.email?.trim().toLowerCase() ?? '',
    );
  }

  Future<SessionData> _sessionFromAuthUser({
    required firebase_auth.User authUser,
    required String email,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final userData = await _loadUserProfile(authUser.uid, cleanEmail);
    final role = _roleFromValue(userData['role']);
    if (role != UserRole.owner) {
      await _auth.signOut();
      throw const FirebaseWorkspaceException(
        'Only the owner account can use this app.',
      );
    }
    final businessIds = _businessIdsFrom(userData);
    if (businessIds.isEmpty) {
      throw const FirebaseWorkspaceException(
        'No business account is linked to this user.',
      );
    }

    final accounts = <BusinessAccount>[];
    for (final businessId in businessIds) {
      accounts.add(
        await _loadBusinessAccount(
          businessId: businessId,
          fallbackOwner: _stringValue(userData['name'], 'Owner'),
          role: role,
        ),
      );
    }

    return SessionData(
      user: AppUser(
        id: authUser.uid,
        name: _stringValue(userData['name'], 'Owner'),
        email: _stringValue(userData['email'], cleanEmail),
        role: role,
      ),
      accounts: accounts,
    );
  }

  Future<void> signOut() {
    return _auth.signOut();
  }

  Future<Map<String, dynamic>> _loadUserProfile(
    String uid,
    String email,
  ) async {
    final uidDoc = await _firestore.collection('users').doc(uid).get();
    final uidData = uidDoc.data();
    if (uidData != null) {
      return uidData;
    }

    if (email.trim().isEmpty) {
      throw FirebaseWorkspaceException(
        'User profile not found. Create users/$uid in Firestore.',
      );
    }

    final emailQuery = await _firestore
        .collection('users')
        .where('email', isEqualTo: email)
        .limit(1)
        .get();
    if (emailQuery.docs.isNotEmpty) {
      return emailQuery.docs.first.data();
    }

    throw FirebaseWorkspaceException(
      'User profile not found. Create users/$uid in Firestore.',
    );
  }

  Future<BusinessAccount> _loadBusinessAccount({
    required String businessId,
    required String fallbackOwner,
    required UserRole role,
  }) async {
    final snapshot = await _firestore
        .collection('businesses')
        .doc(businessId)
        .get();
    final data = snapshot.data() ?? <String, dynamic>{};

    return BusinessAccount(
      id: businessId,
      shopName: _stringValue(data['shopName'], businessId),
      ownerName: _stringValue(data['ownerName'], fallbackOwner),
      role: role,
      customers: await _loadCustomers(businessId),
      bills: await _loadBills(businessId),
      stock: await _loadStock(businessId),
      releases: await _loadReleases(businessId),
      repository: this,
    );
  }

  Future<void> createBusinessAccount({
    required BusinessAccount account,
    required AppUser owner,
  }) async {
    final batch = _firestore.batch();
    final businessRef = _businessRef(account.id);
    batch.set(businessRef, <String, Object?>{
      'shopName': account.shopName,
      'ownerName': account.ownerName,
      'ownerEmail': owner.email,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_firestore.collection('users').doc(owner.id), <String, Object?>{
      'name': owner.name,
      'email': owner.email,
      'role': owner.role.name,
      'active': true,
      'businessId': account.id,
      'businessIds': FieldValue.arrayUnion(<String>[account.id]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await batch.commit();
  }

  Future<CustomerProfile> saveCustomer(
    String businessId,
    CustomerProfile customer, {
    XFile? image,
  }) async {
    var savedCustomer = customer;
    if (image != null) {
      savedCustomer = await _saveCustomerImageLocally(
        businessId: businessId,
        customer: customer,
        image: image,
      );
    }

    await _businessRef(
      businessId,
    ).collection('customers').doc(savedCustomer.id).set(savedCustomer.toMap());
    return savedCustomer;
  }

  Future<void> deleteCustomer(
    String businessId,
    CustomerProfile customer,
  ) async {
    await _businessRef(
      businessId,
    ).collection('customers').doc(customer.id).delete();
    await _deleteCustomerImageLocally(businessId, customer);
  }

  Future<void> saveEntryAndStock({
    required String businessId,
    required BillEntry bill,
    required StockItem stockItem,
    ReleaseEntry? release,
  }) async {
    final batch = _firestore.batch();
    final businessRef = _businessRef(businessId);
    batch.set(businessRef.collection('bills').doc(bill.id), bill.toMap());
    batch.set(
      businessRef.collection('stock').doc(stockItem.id),
      stockItem.toMap(billId: bill.id),
    );
    if (release != null) {
      batch.set(
        businessRef.collection('releases').doc(release.id),
        release.toMap(),
      );
    }
    await batch.commit();
  }

  Future<void> updateBillRecord({
    required String businessId,
    required BillEntry bill,
    required List<StockItem> stockItems,
    required List<ReleaseEntry> oldReleases,
    ReleaseEntry? release,
  }) async {
    final batch = _firestore.batch();
    final businessRef = _businessRef(businessId);

    batch.set(businessRef.collection('bills').doc(bill.id), bill.toMap());

    final linkedStockItems = stockItems.isEmpty
        ? <StockItem>[
            StockItem(
              id: 'stock_${bill.id}',
              billId: bill.id,
              billNo: bill.billNo,
              date: bill.date,
              customerName: bill.customerName,
              jewels: bill.jewels,
              amount: bill.amount,
              weight: bill.weight,
              status: bill.status.stockStatus,
            ),
          ]
        : stockItems;

    for (final item in linkedStockItems) {
      final updatedStock = StockItem(
        id: item.id,
        billId: item.billId ?? bill.id,
        billNo: bill.billNo,
        date: bill.date,
        customerName: bill.customerName,
        jewels: bill.jewels,
        amount: bill.amount,
        weight: bill.weight,
        status: bill.status.stockStatus,
      );
      batch.set(
        businessRef.collection('stock').doc(updatedStock.id),
        updatedStock.toMap(billId: bill.id),
      );
    }

    for (final oldRelease in oldReleases) {
      if (release == null || oldRelease.id != release.id) {
        batch.delete(businessRef.collection('releases').doc(oldRelease.id));
      }
    }
    if (release != null) {
      batch.set(
        businessRef.collection('releases').doc(release.id),
        release.toMap(),
      );
    }

    await batch.commit();
  }

  Future<void> releaseStock({
    required String businessId,
    required StockItem stockItem,
    required ReleaseEntry release,
  }) async {
    final batch = _firestore.batch();
    final businessRef = _businessRef(businessId);
    final billId = stockItem.billId;

    batch.update(businessRef.collection('stock').doc(stockItem.id), {
      'status': StockStatus.released.firestoreValue,
      'releasedAt': FieldValue.serverTimestamp(),
    });
    if (billId != null) {
      batch.update(businessRef.collection('bills').doc(billId), {
        'status': EntryStatus.released.firestoreValue,
        'releaseDate': release.releaseDate,
        'releasedAt': FieldValue.serverTimestamp(),
      });
    }
    batch.set(
      businessRef.collection('releases').doc(release.id),
      release.toMap(),
    );
    await batch.commit();
  }

  Future<void> deleteBillRecord({
    required String businessId,
    required BillEntry bill,
    required List<StockItem> stockItems,
    required List<ReleaseEntry> releases,
  }) async {
    final batch = _firestore.batch();
    final businessRef = _businessRef(businessId);

    batch.delete(businessRef.collection('bills').doc(bill.id));
    for (final item in stockItems) {
      batch.delete(businessRef.collection('stock').doc(item.id));
    }
    for (final release in releases) {
      batch.delete(businessRef.collection('releases').doc(release.id));
    }
    await batch.commit();
  }

  Future<void> deleteStockItem({
    required String businessId,
    required StockItem stockItem,
  }) async {
    await _businessRef(
      businessId,
    ).collection('stock').doc(stockItem.id).delete();
  }

  Future<void> deleteReleaseRecord({
    required String businessId,
    required ReleaseEntry release,
  }) async {
    await _businessRef(
      businessId,
    ).collection('releases').doc(release.id).delete();
  }

  Future<void> releaseBill({
    required String businessId,
    required BillEntry bill,
    required StockItem? stockItem,
    required ReleaseEntry release,
  }) async {
    final batch = _firestore.batch();
    final businessRef = _businessRef(businessId);

    batch.update(businessRef.collection('bills').doc(bill.id), {
      'status': EntryStatus.released.firestoreValue,
      'releaseDate': release.releaseDate,
      'releasedAt': FieldValue.serverTimestamp(),
    });
    if (stockItem != null) {
      batch.update(businessRef.collection('stock').doc(stockItem.id), {
        'status': StockStatus.released.firestoreValue,
        'releasedAt': FieldValue.serverTimestamp(),
      });
    }
    batch.set(
      businessRef.collection('releases').doc(release.id),
      release.toMap(),
    );
    await batch.commit();
  }

  Future<List<CustomerProfile>> _loadCustomers(String businessId) async {
    final snapshot = await _businessRef(
      businessId,
    ).collection('customers').get();
    final customers = <CustomerProfile>[];
    for (final doc in snapshot.docs) {
      final customer = CustomerProfile.fromMap(doc.id, doc.data());
      customers.add(await _hydrateLocalCustomerPhoto(businessId, customer));
    }
    customers.sort((a, b) => a.name.compareTo(b.name));
    return customers;
  }

  Future<List<BillEntry>> _loadBills(String businessId) async {
    final snapshot = await _businessRef(businessId).collection('bills').get();
    final bills = snapshot.docs
        .map((doc) => BillEntry.fromMap(doc.id, doc.data()))
        .toList();
    bills.sort((a, b) => a.billNo.compareTo(b.billNo));
    return bills;
  }

  Future<List<StockItem>> _loadStock(String businessId) async {
    final snapshot = await _businessRef(businessId).collection('stock').get();
    final stock = snapshot.docs
        .map((doc) => StockItem.fromMap(doc.id, doc.data()))
        .toList();
    stock.sort((a, b) => a.billNo.compareTo(b.billNo));
    return stock;
  }

  Future<List<ReleaseEntry>> _loadReleases(String businessId) async {
    final snapshot = await _businessRef(
      businessId,
    ).collection('releases').get();
    final releases = snapshot.docs
        .map((doc) => ReleaseEntry.fromMap(doc.id, doc.data()))
        .toList();
    releases.sort((a, b) => a.releaseDate.compareTo(b.releaseDate));
    return releases;
  }

  Future<CustomerProfile> _saveCustomerImageLocally({
    required String businessId,
    required CustomerProfile customer,
    required XFile image,
  }) async {
    final bytes = await image.readAsBytes();
    final directory = await _customerPhotoDirectory(businessId);
    final extension = _safeImageExtension(image.name);
    final fileName = '${customer.id}.$extension';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);

    return customer.copyWith(
      hasImage: true,
      imageUrl: '',
      localPhotoFileName: fileName,
      localPhotoPath: file.path,
    );
  }

  Future<CustomerProfile> _hydrateLocalCustomerPhoto(
    String businessId,
    CustomerProfile customer,
  ) async {
    if (customer.localPhotoFileName.isEmpty) {
      return customer;
    }

    final directory = await _customerPhotoDirectory(businessId);
    final file = File('${directory.path}/${customer.localPhotoFileName}');
    if (await file.exists()) {
      return customer.copyWith(localPhotoPath: file.path);
    }
    return customer.copyWith(localPhotoPath: '');
  }

  Future<void> _deleteCustomerImageLocally(
    String businessId,
    CustomerProfile customer,
  ) async {
    final paths = <String>[
      customer.localPhotoPath,
      if (customer.localPhotoFileName.isNotEmpty)
        '${(await _customerPhotoDirectory(businessId)).path}/${customer.localPhotoFileName}',
    ];

    for (final path in paths) {
      if (path.trim().isEmpty) {
        continue;
      }
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<Directory> _customerPhotoDirectory(String businessId) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${root.path}/psm_jewellers/$businessId/biodata_photos',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> createBiodataBackup(BusinessAccount account) async {
    final root = await getApplicationDocumentsDirectory();
    final backupDirectory = Directory(
      '${root.path}/psm_jewellers/${account.id}/backups',
    );
    await backupDirectory.create(recursive: true);

    final timestamp = _backupTimestamp(DateTime.now());
    final backupFile = File(
      '${backupDirectory.path}/${account.id}_biodata_backup_$timestamp.zip',
    );
    final archive = Archive();
    final customerData = <String, Object?>{
      'businessId': account.id,
      'shopName': account.shopName,
      'createdAt': DateTime.now().toIso8601String(),
      'customers': account.customers
          .map((customer) => customer.toBackupMap())
          .toList(),
    };

    archive.addFile(
      ArchiveFile.string(
        'biodata/customers.json',
        const JsonEncoder.withIndent('  ').convert(customerData),
      ),
    );

    for (final customer in account.customers) {
      final photoPath = customer.localPhotoPath;
      if (photoPath.isEmpty) {
        continue;
      }
      final photo = File(photoPath);
      if (!await photo.exists()) {
        continue;
      }
      final backupName = customer.localPhotoFileName.isNotEmpty
          ? customer.localPhotoFileName
          : photo.uri.pathSegments.last;
      archive.addFile(
        ArchiveFile.stream(
          'biodata_photos/$backupName',
          InputFileStream(photo.path),
        ),
      );
    }

    final bytes = ZipEncoder().encode(archive);
    await backupFile.writeAsBytes(bytes, flush: true);
    return backupFile;
  }

  DocumentReference<Map<String, dynamic>> _businessRef(String businessId) {
    return _firestore.collection('businesses').doc(businessId);
  }

  List<String> _businessIdsFrom(Map<String, dynamic> data) {
    final ids = <String>{};
    final businessId = data['businessId'];
    if (businessId is String && businessId.trim().isNotEmpty) {
      ids.add(businessId.trim());
    }

    final businessIds = data['businessIds'];
    if (businessIds is Iterable) {
      for (final id in businessIds) {
        if (id is String && id.trim().isNotEmpty) {
          ids.add(id.trim());
        }
      }
    }

    return ids.toList();
  }

  UserRole _roleFromValue(Object? value) {
    return value.toString().toLowerCase() == 'staff'
        ? UserRole.staff
        : UserRole.owner;
  }

  String _stringValue(Object? value, String fallback) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return fallback;
  }
}

class BusinessAccount {
  BusinessAccount({
    required this.id,
    required this.shopName,
    required this.ownerName,
    required this.role,
    required this.customers,
    required this.bills,
    required this.stock,
    required this.releases,
    this.repository,
  });

  final String id;
  final String shopName;
  final String ownerName;
  final UserRole role;
  final List<CustomerProfile> customers;
  final List<BillEntry> bills;
  final List<StockItem> stock;
  final List<ReleaseEntry> releases;
  final FirebaseWorkspaceRepository? repository;

  bool get isOwner => role == UserRole.owner;

  int get totalAmount =>
      bills.fold<int>(0, (total, bill) => total + bill.amount);

  int get presentStockCount =>
      stock.where((item) => item.status == StockStatus.present).length;

  int get pendingBillCount =>
      bills.where((bill) => bill.status == EntryStatus.pending).length;

  String get formattedAmount => MoneyText.format(totalAmount);

  Future<CustomerProfile> saveCustomer(
    CustomerProfile customer, {
    XFile? image,
  }) {
    return repository?.saveCustomer(id, customer, image: image) ??
        Future<CustomerProfile>.value(customer);
  }

  Future<void> deleteCustomer(CustomerProfile customer) {
    return repository?.deleteCustomer(id, customer) ?? Future<void>.value();
  }

  Future<void> saveEntryAndStock({
    required BillEntry bill,
    required StockItem stockItem,
    ReleaseEntry? release,
  }) {
    return repository?.saveEntryAndStock(
          businessId: id,
          bill: bill,
          stockItem: stockItem,
          release: release,
        ) ??
        Future<void>.value();
  }

  Future<void> updateBillRecord({
    required BillEntry bill,
    required List<StockItem> stockItems,
    required List<ReleaseEntry> oldReleases,
    ReleaseEntry? release,
  }) {
    return repository?.updateBillRecord(
          businessId: id,
          bill: bill,
          stockItems: stockItems,
          oldReleases: oldReleases,
          release: release,
        ) ??
        Future<void>.value();
  }

  Future<void> releaseStock({
    required StockItem stockItem,
    required ReleaseEntry release,
  }) {
    return repository?.releaseStock(
          businessId: id,
          stockItem: stockItem,
          release: release,
        ) ??
        Future<void>.value();
  }

  Future<void> releaseBill({
    required BillEntry bill,
    required StockItem? stockItem,
    required ReleaseEntry release,
  }) {
    return repository?.releaseBill(
          businessId: id,
          bill: bill,
          stockItem: stockItem,
          release: release,
        ) ??
        Future<void>.value();
  }

  Future<void> deleteBillRecord({
    required BillEntry bill,
    required List<StockItem> stockItems,
    required List<ReleaseEntry> releases,
  }) {
    return repository?.deleteBillRecord(
          businessId: id,
          bill: bill,
          stockItems: stockItems,
          releases: releases,
        ) ??
        Future<void>.value();
  }

  Future<void> deleteStockItem(StockItem stockItem) {
    return repository?.deleteStockItem(businessId: id, stockItem: stockItem) ??
        Future<void>.value();
  }

  Future<void> deleteReleaseRecord(ReleaseEntry release) {
    return repository?.deleteReleaseRecord(businessId: id, release: release) ??
        Future<void>.value();
  }

  Future<File> createBiodataBackup() {
    final activeRepository = repository;
    if (activeRepository == null) {
      return Future<File>.error(
        const FirebaseWorkspaceException('Backup is available after login.'),
      );
    }
    return activeRepository.createBiodataBackup(this);
  }
}

class CustomerProfile {
  CustomerProfile({
    required this.id,
    required this.name,
    required this.fatherOrHusbandName,
    required this.areaName,
    required this.streetName,
    required this.mobileNumber,
    required this.hasImage,
    this.imageUrl = '',
    this.localPhotoFileName = '',
    this.localPhotoPath = '',
  });

  factory CustomerProfile.fromMap(String id, Map<String, dynamic> data) {
    final imageUrl = _readString(data['imageUrl']);
    final localPhotoFileName = _readString(data['localPhotoFileName']);
    final legacyLocalPhotoPath = _readString(data['localPhotoPath']);
    return CustomerProfile(
      id: id,
      name: _readString(data['name']),
      fatherOrHusbandName: _readString(data['fatherOrHusbandName']),
      areaName: _readString(data['areaName']),
      streetName: _readString(data['streetName']),
      mobileNumber: _readString(data['mobileNumber']),
      hasImage:
          _readBool(data['hasImage']) ||
          imageUrl.isNotEmpty ||
          localPhotoFileName.isNotEmpty ||
          legacyLocalPhotoPath.isNotEmpty,
      imageUrl: imageUrl,
      localPhotoFileName: localPhotoFileName,
      localPhotoPath: legacyLocalPhotoPath,
    );
  }

  final String id;
  final String name;
  final String fatherOrHusbandName;
  final String areaName;
  final String streetName;
  final String mobileNumber;
  final bool hasImage;
  final String imageUrl;
  final String localPhotoFileName;
  final String localPhotoPath;

  CustomerProfile copyWith({
    bool? hasImage,
    String? imageUrl,
    String? localPhotoFileName,
    String? localPhotoPath,
  }) {
    return CustomerProfile(
      id: id,
      name: name,
      fatherOrHusbandName: fatherOrHusbandName,
      areaName: areaName,
      streetName: streetName,
      mobileNumber: mobileNumber,
      hasImage: hasImage ?? this.hasImage,
      imageUrl: imageUrl ?? this.imageUrl,
      localPhotoFileName: localPhotoFileName ?? this.localPhotoFileName,
      localPhotoPath: localPhotoPath ?? this.localPhotoPath,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'name': name,
      'fatherOrHusbandName': fatherOrHusbandName,
      'areaName': areaName,
      'streetName': streetName,
      'mobileNumber': mobileNumber,
      'hasImage': hasImage,
      'imageUrl': imageUrl,
      'localPhotoFileName': localPhotoFileName,
      'photoStorage': localPhotoFileName.isEmpty ? null : 'local',
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Map<String, Object?> toBackupMap() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'fatherOrHusbandName': fatherOrHusbandName,
      'areaName': areaName,
      'streetName': streetName,
      'mobileNumber': mobileNumber,
      'hasImage': hasImage,
      'localPhotoFileName': localPhotoFileName,
    };
  }

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return 'C';
    }
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

class BillEntry {
  BillEntry({
    required this.id,
    required this.billNo,
    required this.date,
    required this.customerName,
    required this.fatherOrHusbandName,
    required this.areaName,
    required this.jewels,
    required this.amount,
    required this.weight,
    required this.status,
    this.releaseDate = '',
  });

  factory BillEntry.fromMap(String id, Map<String, dynamic> data) {
    return BillEntry(
      id: id,
      billNo: _readString(data['billNo']),
      date: _readString(data['date']),
      customerName: _readString(data['customerName']),
      fatherOrHusbandName: _readString(data['fatherOrHusbandName']),
      areaName: _readString(data['areaName']),
      jewels: _readString(data['jewels']),
      amount: _readInt(data['amount']),
      weight: _readString(data['weight']),
      status: _entryStatusFrom(data['status']),
      releaseDate: _readString(data['releaseDate']),
    );
  }

  final String id;
  final String billNo;
  final String date;
  final String customerName;
  final String fatherOrHusbandName;
  final String areaName;
  final String jewels;
  final int amount;
  final String weight;
  EntryStatus status;
  String releaseDate;

  String get registerLine {
    return <String>[
      billNo,
      date,
      customerName,
      areaName,
      jewels,
      amount.toString(),
      weight,
    ].where((part) => part.trim().isNotEmpty).join(' ');
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'billNo': billNo,
      'date': date,
      'customerName': customerName,
      'fatherOrHusbandName': fatherOrHusbandName,
      'areaName': areaName,
      'jewels': jewels,
      'amount': amount,
      'weight': weight,
      'status': status.firestoreValue,
      'releaseDate': releaseDate,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}

enum EntryStatus { pending, released }

extension EntryStatusLabel on EntryStatus {
  String get label {
    switch (this) {
      case EntryStatus.pending:
        return 'Pending';
      case EntryStatus.released:
        return 'Released';
    }
  }

  String get pdfLabel {
    switch (this) {
      case EntryStatus.pending:
        return 'PENDING';
      case EntryStatus.released:
        return 'RELEASED';
    }
  }

  String get firestoreValue {
    switch (this) {
      case EntryStatus.pending:
        return 'pending';
      case EntryStatus.released:
        return 'released';
    }
  }

  StockStatus get stockStatus {
    switch (this) {
      case EntryStatus.pending:
        return StockStatus.present;
      case EntryStatus.released:
        return StockStatus.released;
    }
  }
}

enum PdfStatusFilter { all, pending, released }

extension PdfStatusFilterLabel on PdfStatusFilter {
  String get label {
    switch (this) {
      case PdfStatusFilter.all:
        return 'All';
      case PdfStatusFilter.pending:
        return 'Pending';
      case PdfStatusFilter.released:
        return 'Released';
    }
  }

  String get fileNamePart {
    switch (this) {
      case PdfStatusFilter.all:
        return 'all';
      case PdfStatusFilter.pending:
        return 'pending';
      case PdfStatusFilter.released:
        return 'released';
    }
  }

  bool matches(BillEntry bill) {
    switch (this) {
      case PdfStatusFilter.all:
        return true;
      case PdfStatusFilter.pending:
        return bill.status == EntryStatus.pending;
      case PdfStatusFilter.released:
        return bill.status == EntryStatus.released;
    }
  }
}

enum StockStatus { present, released }

extension StockStatusLabel on StockStatus {
  String get label {
    switch (this) {
      case StockStatus.present:
        return 'Present';
      case StockStatus.released:
        return 'Released';
    }
  }

  String get firestoreValue {
    switch (this) {
      case StockStatus.present:
        return 'present';
      case StockStatus.released:
        return 'released';
    }
  }
}

class StockItem {
  StockItem({
    required this.id,
    this.billId,
    required this.billNo,
    required this.date,
    required this.customerName,
    required this.jewels,
    required this.amount,
    required this.weight,
    required this.status,
  });

  factory StockItem.fromMap(String id, Map<String, dynamic> data) {
    return StockItem(
      id: id,
      billId:
          _readNullableString(data['billId']) ??
          (id.startsWith('stock_') ? id.substring(6) : null),
      billNo: _readString(data['billNo']),
      date: _readString(data['date']),
      customerName: _readString(data['customerName']),
      jewels: _readString(data['jewels']),
      amount: _readInt(data['amount']),
      weight: _readString(data['weight']),
      status: _stockStatusFrom(data['status']),
    );
  }

  final String id;
  final String? billId;
  final String billNo;
  final String date;
  final String customerName;
  final String jewels;
  final int amount;
  final String weight;
  StockStatus status;

  Map<String, Object?> toMap({String? billId}) {
    return <String, Object?>{
      'billId': billId ?? this.billId,
      'billNo': billNo,
      'date': date,
      'customerName': customerName,
      'jewels': jewels,
      'amount': amount,
      'weight': weight,
      'status': status.firestoreValue,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}

class ReleaseEntry {
  ReleaseEntry({
    required this.id,
    required this.billNo,
    required this.releaseDate,
    required this.customerName,
    required this.jewels,
    required this.amount,
    required this.weight,
    required this.releasedBy,
  });

  factory ReleaseEntry.fromMap(String id, Map<String, dynamic> data) {
    return ReleaseEntry(
      id: id,
      billNo: _readString(data['billNo']),
      releaseDate: _readString(data['releaseDate']),
      customerName: _readString(data['customerName']),
      jewels: _readString(data['jewels']),
      amount: _readInt(data['amount']),
      weight: _readString(data['weight']),
      releasedBy: _readString(data['releasedBy']),
    );
  }

  final String id;
  final String billNo;
  final String releaseDate;
  final String customerName;
  final String jewels;
  final int amount;
  final String weight;
  final String releasedBy;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'billNo': billNo,
      'releaseDate': releaseDate,
      'customerName': customerName,
      'jewels': jewels,
      'amount': amount,
      'weight': weight,
      'releasedBy': releasedBy,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}

String _readString(Object? value, [String fallback = '']) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return fallback;
}

String? _readNullableString(Object? value) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return null;
}

int _readInt(Object? value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _readBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return value.toLowerCase() == 'true';
  }
  return false;
}

EntryStatus _entryStatusFrom(Object? value) {
  return value.toString().toLowerCase() == EntryStatus.released.firestoreValue
      ? EntryStatus.released
      : EntryStatus.pending;
}

StockStatus _stockStatusFrom(Object? value) {
  return value.toString().toLowerCase() == StockStatus.released.firestoreValue
      ? StockStatus.released
      : StockStatus.present;
}

class MockWorkspace {
  static List<BusinessAccount> accounts() {
    final psmCustomers = <CustomerProfile>[
      CustomerProfile(
        id: 'cus_1',
        name: 'Sandhiya',
        fatherOrHusbandName: 'Munusamy',
        areaName: 'Vengal',
        streetName: 'North Street',
        mobileNumber: '9943211818',
        hasImage: true,
      ),
      CustomerProfile(
        id: 'cus_2',
        name: 'Kanchana',
        fatherOrHusbandName: 'Prakash',
        areaName: 'Sembedu',
        streetName: 'Main Road',
        mobileNumber: '9843021142',
        hasImage: false,
      ),
      CustomerProfile(
        id: 'cus_3',
        name: 'Meena',
        fatherOrHusbandName: 'Sankar',
        areaName: 'Mamballam',
        streetName: 'Temple Street',
        mobileNumber: '9092813412',
        hasImage: true,
      ),
    ];

    final psmBills = <BillEntry>[
      BillEntry(
        id: 'bill_1',
        billNo: 'H2992',
        date: '13.10.25',
        customerName: 'SANDHIYA',
        fatherOrHusbandName: 'MUNUSAMY',
        areaName: 'VENGAL',
        jewels: 'FANCYKAMAL',
        amount: 20000,
        weight: '3.600ML',
        status: EntryStatus.pending,
      ),
      BillEntry(
        id: 'bill_2',
        billNo: 'H2993',
        date: '13.10.25',
        customerName: 'KANCHANA',
        fatherOrHusbandName: 'PRAKASH',
        areaName: 'SEMBEDU',
        jewels: 'JEWELS',
        amount: 20400,
        weight: '3GM',
        status: EntryStatus.pending,
      ),
      BillEntry(
        id: 'bill_3',
        billNo: 'H2995',
        date: '13.10.25',
        customerName: 'MEENA',
        fatherOrHusbandName: 'SANKAR',
        areaName: 'MAMBALLAM',
        jewels: 'GOLUSU',
        amount: 7500,
        weight: '193GM',
        status: EntryStatus.released,
      ),
    ];

    return <BusinessAccount>[
      BusinessAccount(
        id: 'psm',
        shopName: 'P S M Jewellers',
        ownerName: 'Subash',
        role: UserRole.owner,
        customers: psmCustomers,
        bills: psmBills,
        stock: psmBills
            .map(
              (bill) => StockItem(
                id: 'stock_${bill.id}',
                billNo: bill.billNo,
                date: bill.date,
                customerName: bill.customerName,
                jewels: bill.jewels,
                amount: bill.amount,
                weight: bill.weight,
                status: bill.status.stockStatus,
              ),
            )
            .toList(),
        releases: <ReleaseEntry>[],
      ),
      BusinessAccount(
        id: 'branch',
        shopName: 'Second Business Account',
        ownerName: 'Subash',
        role: UserRole.owner,
        customers: <CustomerProfile>[],
        bills: <BillEntry>[],
        stock: <StockItem>[],
        releases: <ReleaseEntry>[],
      ),
    ];
  }
}

class MoneyText {
  static String format(int value) {
    return 'Rs. $value';
  }
}

class PsmColors {
  static const Color canvas = Color(0xFFFFFBF2);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF17130D);
  static const Color muted = Color(0xFF756B5C);
  static const Color forest = Color(0xFF68766B);
  static const Color forestDeep = Color(0xFF59665D);
  static const Color gold = Color(0xFFC49424);
  static const Color goldDeep = Color(0xFF9E7415);
  static const Color goldSoft = Color(0xFFF4E3AE);
  static const Color line = Color(0xFFE8DDC4);
  static const Color danger = Color(0xFF9B2F2F);
}

class PsmTheme {
  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: PsmColors.gold,
      brightness: Brightness.light,
      primary: PsmColors.forest,
      secondary: PsmColors.gold,
      surface: PsmColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: PsmColors.canvas,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: PsmColors.canvas,
        foregroundColor: PsmColors.ink,
        titleTextStyle: TextStyle(
          color: PsmColors.ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 31,
          fontWeight: FontWeight.w900,
          height: 1.05,
          color: PsmColors.ink,
        ),
        headlineMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          height: 1.12,
          color: PsmColors.ink,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: PsmColors.ink,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: PsmColors.ink,
        ),
        bodyLarge: TextStyle(fontSize: 16, height: 1.35, color: PsmColors.ink),
        bodyMedium: TextStyle(
          fontSize: 14,
          height: 1.35,
          color: PsmColors.muted,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: PsmColors.surface,
        labelStyle: const TextStyle(color: PsmColors.muted),
        floatingLabelStyle: const TextStyle(color: PsmColors.forest),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: PsmColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: PsmColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: PsmColors.goldDeep, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: PsmColors.forest,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: PsmColors.forest,
          minimumSize: const Size.fromHeight(50),
          side: const BorderSide(color: PsmColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: PsmColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: PsmColors.line),
        ),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFFFFF7DE),
              Color(0xFFF4D06A),
              Color(0xFF2F4C25),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              BrandMark(size: 94, light: true),
              SizedBox(height: 18),
              Text(
                'P S M Jewellers',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Girvi register and release records',
                style: TextStyle(
                  color: Color(0xFFFFF7DE),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 46, this.light = false});

  final double size;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final background = light ? Colors.white : PsmColors.forest;
    final foreground = light ? PsmColors.forest : Colors.white;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(Icons.diamond_rounded, color: PsmColors.gold, size: size * 0.42),
          Positioned(
            bottom: size * 0.16,
            child: Text(
              'PSM',
              style: TextStyle(
                color: foreground,
                fontSize: size * 0.18,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});

  final Future<void> Function(String email, String password) onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Enter email and password');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await widget.onLogin(email, password);
    } on firebase_auth.FirebaseAuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _authErrorMessage(error);
        _isSubmitting = false;
      });
    } on FirebaseWorkspaceException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _isSubmitting = false;
      });
    } on FirebaseException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message ?? 'Firebase request failed.';
        _isSubmitting = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Unable to sign in. Please try again.';
        _isSubmitting = false;
      });
    }
  }

  String _authErrorMessage(firebase_auth.FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Email or password is wrong.';
      case 'network-request-failed':
        return 'Network issue. Check internet and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Try again after some time.';
      default:
        return error.message ?? 'Firebase login failed.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
          children: <Widget>[
            const Align(
              alignment: Alignment.centerLeft,
              child: BrandMark(size: 66),
            ),
            const SizedBox(height: 14),
            const Text(
              'P S M Jewellers',
              style: TextStyle(
                color: PsmColors.forest,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Sign in to your jewellery workspace',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 10),
            Text(
              'Owner-only access for customers, bills, releases, and PDF reports.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email address',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                ),
              ),
            ),
            const SizedBox(height: 22),
            if (_errorMessage != null) ...<Widget>[
              ErrorStrip(message: _errorMessage!),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _isSubmitting ? null : _submit,
              icon: _isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(_isSubmitting ? 'Signing in...' : 'Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

class AccountSwitcherScreen extends StatelessWidget {
  const AccountSwitcherScreen({
    super.key,
    required this.user,
    required this.accounts,
    required this.onAccountSelected,
    required this.onCreateFreshAccount,
    required this.onSignOut,
  });

  final AppUser user;
  final List<BusinessAccount> accounts;
  final ValueChanged<BusinessAccount> onAccountSelected;
  final VoidCallback onCreateFreshAccount;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
            children: <Widget>[
              Row(
                children: <Widget>[
                  const BrandMark(size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Choose account',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          user.email,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sign out',
                    onPressed: onSignOut,
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              for (final account in accounts) ...<Widget>[
                AccountCard(
                  account: account,
                  onTap: () => onAccountSelected(account),
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              if (user.role == UserRole.owner)
                OutlinedButton.icon(
                  onPressed: onCreateFreshAccount,
                  icon: const Icon(Icons.add_business_rounded),
                  label: const Text('Create fresh business account'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AccountCard extends StatelessWidget {
  const AccountCard({super.key, required this.account, required this.onTap});

  final BusinessAccount account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: PsmColors.goldSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.storefront_rounded,
                  color: PsmColors.goldDeep,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      account.shopName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      account.role.label,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        MiniChip(
                          label: '${account.customers.length} customers',
                        ),
                        MiniChip(label: '${account.bills.length} bills'),
                        MiniChip(label: '${account.pendingBillCount} pending'),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.user,
    required this.account,
    required this.onSwitchAccount,
    required this.onSignOut,
  });

  final AppUser user;
  final BusinessAccount account;
  final VoidCallback onSwitchAccount;
  final VoidCallback onSignOut;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;

  void _selectTab(int index) {
    setState(() => _tabIndex = index);
  }

  void _handleBack() {
    if (_tabIndex != 0) {
      setState(() => _tabIndex = 0);
    }
  }

  void _openPage(Widget page) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => page));
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardScreen(
        account: widget.account,
        user: widget.user,
        onSwitchAccount: widget.onSwitchAccount,
        onOpenCustomers: () => _selectTab(1),
        onOpenEntry: () => _selectTab(2),
        onOpenBills: () => _openPage(BillsScreen(account: widget.account)),
        onOpenPending: () =>
            _openPage(PendingBillsScreen(account: widget.account)),
        onOpenRelease: () => _openPage(ReleaseScreen(account: widget.account)),
        onOpenPdf: () => _openPage(PdfScreen(account: widget.account)),
      ),
      CustomersScreen(account: widget.account),
      NewEntryScreen(account: widget.account),
      MoreScreen(
        account: widget.account,
        user: widget.user,
        onSwitchAccount: widget.onSwitchAccount,
        onSignOut: widget.onSignOut,
        onOpenBills: () => _openPage(BillsScreen(account: widget.account)),
        onOpenPending: () =>
            _openPage(PendingBillsScreen(account: widget.account)),
        onOpenRelease: () => _openPage(ReleaseScreen(account: widget.account)),
        onOpenPdf: () => _openPage(PdfScreen(account: widget.account)),
        onOpenSearch: () => _openPage(SearchScreen(account: widget.account)),
      ),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleBack();
        }
      },
      child: Scaffold(
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: pages[_tabIndex],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: _selectTab,
          backgroundColor: PsmColors.surface,
          indicatorColor: PsmColors.goldSoft,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline_rounded),
              selectedIcon: Icon(Icons.people_rounded),
              label: 'Customers',
            ),
            NavigationDestination(
              icon: Icon(Icons.add_circle_outline_rounded),
              selectedIcon: Icon(Icons.add_circle_rounded),
              label: 'Entry',
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz_rounded),
              selectedIcon: Icon(Icons.more_rounded),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.account,
    required this.user,
    required this.onSwitchAccount,
    required this.onOpenCustomers,
    required this.onOpenEntry,
    required this.onOpenBills,
    required this.onOpenPending,
    required this.onOpenRelease,
    required this.onOpenPdf,
  });

  final BusinessAccount account;
  final AppUser user;
  final VoidCallback onSwitchAccount;
  final VoidCallback onOpenCustomers;
  final VoidCallback onOpenEntry;
  final VoidCallback onOpenBills;
  final VoidCallback onOpenPending;
  final VoidCallback onOpenRelease;
  final VoidCallback onOpenPdf;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
        children: <Widget>[
          Row(
            children: <Widget>[
              const BrandMark(size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Hi ${user.name}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      account.shopName,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onSwitchAccount,
                icon: const Icon(Icons.swap_horiz_rounded),
                label: const Text('Switch'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Quick actions', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.18,
            children: <Widget>[
              ActionTile(
                icon: Icons.person_add_alt_1_rounded,
                label: 'Customer Bio Data',
                caption: 'Separate customer record',
                onTap: onOpenCustomers,
              ),
              ActionTile(
                icon: Icons.edit_document,
                label: 'New Entry',
                caption: 'Bill and jewels entry',
                onTap: onOpenEntry,
              ),
              if (account.isOwner) ...<Widget>[
                ActionTile(
                  icon: Icons.receipt_long_rounded,
                  label: 'Daily Bills',
                  caption: 'Register lines',
                  onTap: onOpenBills,
                ),
                ActionTile(
                  icon: Icons.pending_actions_rounded,
                  label: 'Pending Bills',
                  caption: '${account.pendingBillCount} waiting',
                  onTap: onOpenPending,
                ),
                ActionTile(
                  icon: Icons.lock_open_rounded,
                  label: 'Released Bills',
                  caption: 'Closed register lines',
                  onTap: onOpenRelease,
                ),
                ActionTile(
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'Generate PDF',
                  caption: 'Date filter export',
                  onTap: onOpenPdf,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String _query = '';
  final Set<String> _deletingCustomerIds = <String>{};

  Future<void> _deleteCustomer(CustomerProfile customer) {
    return _deleteCustomerRecord(
      context: context,
      account: widget.account,
      customer: customer,
      deletingCustomerIds: _deletingCustomerIds,
      setScreenState: setState,
    );
  }

  void _openCustomerForm({CustomerProfile? customer}) {
    final isEditing = customer != null;
    final nameController = TextEditingController(text: customer?.name ?? '');
    final relationController = TextEditingController(
      text: customer?.fatherOrHusbandName ?? '',
    );
    final areaController = TextEditingController(
      text: customer?.areaName ?? '',
    );
    final streetController = TextEditingController(
      text: customer?.streetName ?? '',
    );
    final mobileController = TextEditingController(
      text: customer?.mobileNumber ?? '',
    );
    XFile? selectedImage;
    var isSaving = false;
    final customerNameSuggestions = _uniqueSuggestions(
      widget.account.customers.map((customer) => customer.name),
    );
    final relationSuggestions = _uniqueSuggestions(
      widget.account.customers.map((customer) => customer.fatherOrHusbandName),
    );
    final areaSuggestions = _uniqueSuggestions(
      widget.account.customers.map((customer) => customer.areaName),
    );
    final streetSuggestions = _uniqueSuggestions(
      widget.account.customers.map((customer) => customer.streetName),
    );
    final mobileSuggestions = _uniqueSuggestions(
      widget.account.customers.map((customer) => customer.mobileNumber),
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: PsmColors.canvas,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            ImageProvider<Object>? photoProvider;
            if (selectedImage != null) {
              photoProvider = FileImage(File(selectedImage!.path));
            } else if (customer != null &&
                customer.localPhotoPath.isNotEmpty &&
                File(customer.localPhotoPath).existsSync()) {
              photoProvider = FileImage(File(customer.localPhotoPath));
            } else if (customer != null && customer.imageUrl.isNotEmpty) {
              photoProvider = NetworkImage(customer.imageUrl);
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                4,
                18,
                MediaQuery.of(context).viewInsets.bottom + 18,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      isEditing
                          ? 'Edit Customer Bio Data'
                          : 'New Customer Bio Data',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(28),
                        onTap: isSaving
                            ? null
                            : () async {
                                final image = await ImagePicker().pickImage(
                                  source: ImageSource.gallery,
                                  imageQuality: 72,
                                );
                                if (image != null) {
                                  setSheetState(() => selectedImage = image);
                                }
                              },
                        child: Container(
                          width: 104,
                          height: 104,
                          decoration: BoxDecoration(
                            color: selectedImage != null
                                ? PsmColors.goldSoft
                                : PsmColors.surface,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(color: PsmColors.line),
                            image: photoProvider == null
                                ? null
                                : DecorationImage(
                                    image: photoProvider,
                                    fit: BoxFit.cover,
                                  ),
                          ),
                          child: photoProvider == null
                              ? const Icon(
                                  Icons.add_a_photo_outlined,
                                  color: PsmColors.goldDeep,
                                  size: 34,
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        selectedImage != null
                            ? selectedImage!.name
                            : customer?.hasImage == true
                            ? 'Tap to change customer image'
                            : 'Tap to add customer image',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: nameController,
                      label: 'Customer name',
                      icon: Icons.person_outline_rounded,
                      suggestions: customerNameSuggestions,
                    ),
                    AppTextField(
                      controller: relationController,
                      label: 'Father / Husband name',
                      icon: Icons.family_restroom_rounded,
                      suggestions: relationSuggestions,
                    ),
                    AppTextField(
                      controller: areaController,
                      label: 'Area name',
                      icon: Icons.location_on_outlined,
                      suggestions: areaSuggestions,
                    ),
                    AppTextField(
                      controller: streetController,
                      label: 'Street name',
                      icon: Icons.signpost_outlined,
                      suggestions: streetSuggestions,
                    ),
                    AppTextField(
                      controller: mobileController,
                      label: 'Mobile number',
                      icon: Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                      suggestions: mobileSuggestions,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: isSaving
                          ? null
                          : () async {
                              final name = nameController.text.trim();
                              if (name.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Enter customer name'),
                                  ),
                                );
                                return;
                              }

                              final updatedCustomer = CustomerProfile(
                                id:
                                    customer?.id ??
                                    'cus_${DateTime.now().millisecondsSinceEpoch}',
                                name: name,
                                fatherOrHusbandName: relationController.text
                                    .trim(),
                                areaName: areaController.text.trim(),
                                streetName: streetController.text.trim(),
                                mobileNumber: mobileController.text.trim(),
                                hasImage:
                                    selectedImage != null ||
                                    (customer?.hasImage ?? false),
                                imageUrl: customer?.imageUrl ?? '',
                                localPhotoFileName:
                                    customer?.localPhotoFileName ?? '',
                                localPhotoPath: customer?.localPhotoPath ?? '',
                              );

                              try {
                                final navigator = Navigator.of(sheetContext);
                                final messenger = ScaffoldMessenger.of(
                                  this.context,
                                );
                                setSheetState(() => isSaving = true);
                                final savedCustomer = await widget.account
                                    .saveCustomer(
                                      updatedCustomer,
                                      image: selectedImage,
                                    );
                                if (!mounted || !sheetContext.mounted) {
                                  return;
                                }
                                setState(() {
                                  final existingIndex = widget.account.customers
                                      .indexWhere(
                                        (item) => item.id == savedCustomer.id,
                                      );
                                  if (existingIndex == -1) {
                                    widget.account.customers.add(savedCustomer);
                                  } else {
                                    widget.account.customers[existingIndex] =
                                        savedCustomer;
                                  }
                                });
                                navigator.pop();
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      isEditing
                                          ? 'Customer bio data updated'
                                          : 'Customer bio data saved',
                                    ),
                                  ),
                                );
                              } on FirebaseException catch (error) {
                                if (!mounted || !sheetContext.mounted) {
                                  return;
                                }
                                setSheetState(() => isSaving = false);
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      error.message ?? 'Firebase save failed',
                                    ),
                                  ),
                                );
                              } catch (_) {
                                if (!mounted || !sheetContext.mounted) {
                                  return;
                                }
                                setSheetState(() => isSaving = false);
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Unable to save customer'),
                                  ),
                                );
                              }
                            },
                      icon: isSaving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(
                        isSaving
                            ? 'Saving...'
                            : isEditing
                            ? 'Update customer'
                            : 'Save customer',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final customers = widget.account.customers.where((customer) {
      final text =
          '${customer.name} ${customer.fatherOrHusbandName} ${customer.areaName} ${customer.streetName} ${customer.mobileNumber}'
              .toLowerCase();
      return normalized.isEmpty || text.contains(normalized);
    }).toList();

    return PageFrame(
      title: 'Customer Bio Data',
      subtitle: widget.account.shopName,
      trailing: IconButton.filled(
        onPressed: () => _openCustomerForm(),
        icon: const Icon(Icons.add_rounded),
        tooltip: 'Add customer',
      ),
      child: widget.account.customers.isEmpty
          ? EmptyState(
              icon: Icons.people_outline_rounded,
              title: 'No customers yet',
              message: 'Add the first customer with image and address details.',
              actionLabel: 'Add customer',
              onAction: () => _openCustomerForm(),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: <Widget>[
                RecordSearchField(
                  label: 'Search customers',
                  suggestions: _customerSuggestions(widget.account),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                if (customers.isEmpty)
                  const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No matching customers',
                    message:
                        'Search by name, father/husband, area, street, or mobile.',
                  )
                else
                  for (final customer in customers) ...<Widget>[
                    CustomerTile(
                      customer: customer,
                      onEdit: widget.account.isOwner
                          ? () => _openCustomerForm(customer: customer)
                          : null,
                      onDelete: widget.account.isOwner
                          ? () => _deleteCustomer(customer)
                          : null,
                      isDeleting: _deletingCustomerIds.contains(customer.id),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }
}

class NewEntryScreen extends StatefulWidget {
  const NewEntryScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<NewEntryScreen> createState() => _NewEntryScreenState();
}

class _NewEntryScreenState extends State<NewEntryScreen> {
  late final TextEditingController _billController;
  late final TextEditingController _dateController;
  late final TextEditingController _customerController;
  late final TextEditingController _areaController;
  late final TextEditingController _jewelsController;
  late final TextEditingController _amountController;
  late final TextEditingController _weightController;
  EntryStatus _status = EntryStatus.pending;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _billController = TextEditingController(
      text: 'H${3000 + widget.account.bills.length + 1}',
    );
    _dateController = TextEditingController(
      text: _formatRegisterDate(DateTime.now()),
    );
    _customerController = TextEditingController();
    _areaController = TextEditingController();
    _jewelsController = TextEditingController();
    _amountController = TextEditingController();
    _weightController = TextEditingController();
  }

  @override
  void dispose() {
    _billController.dispose();
    _dateController.dispose();
    _customerController.dispose();
    _areaController.dispose();
    _jewelsController.dispose();
    _amountController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  Future<void> _saveEntry() async {
    final customerName = _customerController.text.trim();
    final areaName = _areaController.text.trim();
    final jewels = _jewelsController.text.trim();
    final amount = int.tryParse(_amountController.text.trim());
    final weight = _weightController.text.trim();
    if (customerName.isEmpty ||
        areaName.isEmpty ||
        jewels.isEmpty ||
        amount == null ||
        weight.isEmpty) {
      _showMessage('Enter all entry fields');
      return;
    }

    final id = 'bill_${DateTime.now().millisecondsSinceEpoch}';
    final bill = BillEntry(
      id: id,
      billNo: _billController.text.trim(),
      date: _dateController.text.trim(),
      customerName: customerName.toUpperCase(),
      fatherOrHusbandName: '',
      areaName: areaName.toUpperCase(),
      jewels: jewels.toUpperCase(),
      amount: amount,
      weight: weight.toUpperCase(),
      status: _status,
      releaseDate: _status == EntryStatus.released
          ? _dateController.text.trim()
          : '',
    );
    final stockItem = StockItem(
      id: 'stock_$id',
      billId: id,
      billNo: bill.billNo,
      date: bill.date,
      customerName: bill.customerName,
      jewels: bill.jewels,
      amount: bill.amount,
      weight: bill.weight,
      status: bill.status.stockStatus,
    );
    final release = bill.status == EntryStatus.released
        ? ReleaseEntry(
            id: 'rel_$id',
            billNo: bill.billNo,
            releaseDate: bill.date,
            customerName: bill.customerName,
            jewels: bill.jewels,
            amount: bill.amount,
            weight: bill.weight,
            releasedBy: widget.account.ownerName,
          )
        : null;

    setState(() => _isSaving = true);

    try {
      await widget.account.saveEntryAndStock(
        bill: bill,
        stockItem: stockItem,
        release: release,
      );
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showMessage(error.message ?? 'Firebase save failed');
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showMessage('Unable to save entry');
      }
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      widget.account.bills.add(bill);
      widget.account.stock.add(stockItem);
      if (release != null) {
        widget.account.releases.add(release);
      }
      _billController.text = 'H${3000 + widget.account.bills.length + 1}';
      _customerController.clear();
      _areaController.clear();
      _jewelsController.clear();
      _amountController.clear();
      _weightController.clear();
      _status = EntryStatus.pending;
      _isSaving = false;
    });

    _showMessage('Entry saved to Firebase');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final customerSuggestions = _uniqueSuggestions(<String>[
      ...widget.account.customers.map((customer) => customer.name),
      ...widget.account.bills.map((bill) => bill.customerName),
      ...widget.account.stock.map((item) => item.customerName),
    ]);
    final areaSuggestions = _uniqueSuggestions(<String>[
      ...widget.account.customers.map((customer) => customer.areaName),
      ...widget.account.bills.map((bill) => bill.areaName),
    ]);
    final jewelsSuggestions = _uniqueSuggestions(<String>[
      ...widget.account.bills.map((bill) => bill.jewels),
      ...widget.account.stock.map((item) => item.jewels),
    ]);
    final amountSuggestions = _uniqueSuggestions(<String>[
      ...widget.account.bills.map((bill) => bill.amount.toString()),
      ...widget.account.stock.map((item) => item.amount.toString()),
    ]);
    final weightSuggestions = _uniqueSuggestions(<String>[
      ...widget.account.bills.map((bill) => bill.weight),
      ...widget.account.stock.map((item) => item.weight),
    ]);
    return PageFrame(
      title: 'New Entry',
      subtitle: 'Bill and jewels entry',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: <Widget>[
          AppTextField(
            controller: _billController,
            label: 'Bill no',
            icon: Icons.confirmation_number_outlined,
          ),
          DateFilterField(
            controller: _dateController,
            label: 'Date',
            onChanged: (_) => setState(() {}),
          ),
          AppTextField(
            controller: _customerController,
            label: 'Customer name',
            icon: Icons.person_outline_rounded,
            suggestions: customerSuggestions,
          ),
          AppTextField(
            controller: _areaController,
            label: 'Area name',
            icon: Icons.location_on_outlined,
            suggestions: areaSuggestions,
          ),
          AppTextField(
            controller: _jewelsController,
            label: 'Jewels details',
            icon: Icons.diamond_outlined,
            suggestions: jewelsSuggestions,
          ),
          AppTextField(
            controller: _amountController,
            label: 'Amount',
            icon: Icons.currency_rupee_rounded,
            keyboardType: TextInputType.number,
            suggestions: amountSuggestions,
          ),
          AppTextField(
            controller: _weightController,
            label: 'Weight',
            icon: Icons.scale_outlined,
            suggestions: weightSuggestions,
          ),
          DropdownButtonFormField<EntryStatus>(
            initialValue: _status,
            items: EntryStatus.values
                .map(
                  (status) => DropdownMenuItem<EntryStatus>(
                    value: status,
                    child: Text(status.label),
                  ),
                )
                .toList(),
            onChanged: (status) {
              if (status != null) {
                setState(() => _status = status);
              }
            },
            decoration: const InputDecoration(
              labelText: 'Status',
              prefixIcon: Icon(Icons.fact_check_outlined),
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _isSaving ? null : _saveEntry,
            icon: _isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded),
            label: Text(_isSaving ? 'Saving...' : 'Save entry'),
          ),
          const SizedBox(height: 18),
          if (widget.account.bills.isNotEmpty)
            RegisterPreviewLine(bill: widget.account.bills.last),
        ],
      ),
    );
  }
}

class BillsScreen extends StatefulWidget {
  const BillsScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  String _query = '';
  final Set<String> _releasingBillIds = <String>{};
  final Set<String> _deletingBillIds = <String>{};

  Future<void> _release(BillEntry bill) {
    return _releasePendingBill(
      context: context,
      account: widget.account,
      bill: bill,
      releasingBillIds: _releasingBillIds,
      setScreenState: setState,
    );
  }

  Future<void> _deleteBill(BillEntry bill) {
    return _deleteBillRecord(
      context: context,
      account: widget.account,
      bill: bill,
      deletingBillIds: _deletingBillIds,
      setScreenState: setState,
    );
  }

  Future<void> _editBill(BillEntry bill) {
    return _openBillEditSheet(
      context: context,
      account: widget.account,
      bill: bill,
      setScreenState: setState,
    );
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final bills = widget.account.bills.where((bill) {
      final text =
          '${bill.billNo} ${bill.date} ${bill.releaseDate} ${bill.customerName} ${bill.areaName} ${bill.jewels} ${bill.amount} ${bill.weight} ${bill.status.label}'
              .toLowerCase();
      return normalized.isEmpty || text.contains(normalized);
    }).toList();

    return PageFrame(
      title: 'Daily Bills',
      subtitle: '25 lines per PDF page later',
      showBack: true,
      child: widget.account.bills.isEmpty
          ? const EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No bills in this account',
              message: 'Entries saved here will not mix with other accounts.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: <Widget>[
                RecordSearchField(
                  label: 'Search bills',
                  suggestions: _billSuggestions(widget.account),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                if (bills.isEmpty)
                  const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No matching bills',
                    message:
                        'Search by bill no, date, customer, area, jewels, amount, weight, or status.',
                  )
                else
                  for (final bill in bills) ...<Widget>[
                    RegisterPreviewLine(
                      bill: bill,
                      onRelease: widget.account.isOwner
                          ? () => _release(bill)
                          : null,
                      isReleasing: _releasingBillIds.contains(bill.id),
                      onEdit: widget.account.isOwner
                          ? () => _editBill(bill)
                          : null,
                      onDelete: widget.account.isOwner
                          ? () => _deleteBill(bill)
                          : null,
                      isDeleting: _deletingBillIds.contains(bill.id),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }
}

class PendingBillsScreen extends StatefulWidget {
  const PendingBillsScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<PendingBillsScreen> createState() => _PendingBillsScreenState();
}

class _PendingBillsScreenState extends State<PendingBillsScreen> {
  late final TextEditingController _fromController;
  late final TextEditingController _toController;
  String _query = '';
  final Set<String> _releasingBillIds = <String>{};
  final Set<String> _deletingBillIds = <String>{};

  @override
  void initState() {
    super.initState();
    _fromController = TextEditingController();
    _toController = TextEditingController();
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _applyToday() {
    final today = _formatRegisterDate(DateTime.now());
    setState(() {
      _fromController.text = today;
      _toController.text = today;
    });
  }

  void _applyThisMonth() {
    final now = DateTime.now();
    setState(() {
      _fromController.text = _formatRegisterDate(DateTime(now.year, now.month));
      _toController.text = _formatRegisterDate(now);
    });
  }

  void _clearFilter() {
    setState(() {
      _fromController.clear();
      _toController.clear();
      _query = '';
    });
  }

  Future<void> _release(BillEntry bill) {
    return _releasePendingBill(
      context: context,
      account: widget.account,
      bill: bill,
      releasingBillIds: _releasingBillIds,
      setScreenState: setState,
    );
  }

  Future<void> _deleteBill(BillEntry bill) {
    return _deleteBillRecord(
      context: context,
      account: widget.account,
      bill: bill,
      deletingBillIds: _deletingBillIds,
      setScreenState: setState,
    );
  }

  Future<void> _editBill(BillEntry bill) {
    return _openBillEditSheet(
      context: context,
      account: widget.account,
      bill: bill,
      setScreenState: setState,
    );
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final fromDate = _parseRegisterDate(_fromController.text);
    final toDate = _parseRegisterDate(_toController.text);
    final pendingBills = widget.account.bills.where((bill) {
      final text =
          '${bill.billNo} ${bill.date} ${bill.customerName} ${bill.areaName} ${bill.jewels} ${bill.amount} ${bill.weight}'
              .toLowerCase();
      return bill.status == EntryStatus.pending &&
          (normalized.isEmpty || text.contains(normalized)) &&
          _isInsideDateRange(bill.date, fromDate: fromDate, toDate: toDate);
    }).toList();

    return PageFrame(
      title: 'Pending Bills',
      subtitle: '${pendingBills.length} waiting for release',
      showBack: true,
      child: widget.account.pendingBillCount == 0
          ? const EmptyState(
              icon: Icons.pending_actions_rounded,
              title: 'No pending bills',
              message: 'Pending entries will appear here until released.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DateFilterField(
                        controller: _fromController,
                        label: 'From date',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DateFilterField(
                        controller: _toController,
                        label: 'To date',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    ActionChip(
                      label: const Text('Today'),
                      onPressed: _applyToday,
                    ),
                    ActionChip(
                      label: const Text('This month'),
                      onPressed: _applyThisMonth,
                    ),
                    ActionChip(
                      label: const Text('All pending'),
                      onPressed: _clearFilter,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                RecordSearchField(
                  label: 'Search pending bills',
                  suggestions: _pendingBillSuggestions(widget.account),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                if (pendingBills.isEmpty)
                  const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No matching pending bills',
                    message:
                        'Search by bill no, date, customer, area, jewels, amount, or weight.',
                  )
                else
                  for (final bill in pendingBills) ...<Widget>[
                    RegisterPreviewLine(
                      bill: bill,
                      onRelease: () => _release(bill),
                      isReleasing: _releasingBillIds.contains(bill.id),
                      onEdit: () => _editBill(bill),
                      onDelete: () => _deleteBill(bill),
                      isDeleting: _deletingBillIds.contains(bill.id),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }
}

class ReleaseScreen extends StatefulWidget {
  const ReleaseScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<ReleaseScreen> createState() => _ReleaseScreenState();
}

class _ReleaseScreenState extends State<ReleaseScreen> {
  late final TextEditingController _fromController;
  late final TextEditingController _toController;
  String _query = '';
  final Set<String> _deletingBillIds = <String>{};

  @override
  void initState() {
    super.initState();
    _fromController = TextEditingController();
    _toController = TextEditingController();
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _applyToday() {
    final today = _formatRegisterDate(DateTime.now());
    setState(() {
      _fromController.text = today;
      _toController.text = today;
    });
  }

  void _applyThisMonth() {
    final now = DateTime.now();
    setState(() {
      _fromController.text = _formatRegisterDate(DateTime(now.year, now.month));
      _toController.text = _formatRegisterDate(now);
    });
  }

  void _clearFilter() {
    setState(() {
      _fromController.clear();
      _toController.clear();
      _query = '';
    });
  }

  Future<void> _deleteBill(BillEntry bill) {
    return _deleteBillRecord(
      context: context,
      account: widget.account,
      bill: bill,
      deletingBillIds: _deletingBillIds,
      setScreenState: setState,
    );
  }

  Future<void> _editBill(BillEntry bill) {
    return _openBillEditSheet(
      context: context,
      account: widget.account,
      bill: bill,
      setScreenState: setState,
    );
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final fromDate = _parseRegisterDate(_fromController.text);
    final toDate = _parseRegisterDate(_toController.text);
    final releasedBills = widget.account.bills.where((bill) {
      final text =
          '${bill.billNo} ${bill.date} ${bill.releaseDate} ${bill.customerName} ${bill.areaName} ${bill.jewels} ${bill.amount} ${bill.weight} ${bill.status.label}'
              .toLowerCase();
      return bill.status == EntryStatus.released &&
          (normalized.isEmpty || text.contains(normalized)) &&
          _isInsideDateRange(
            _pdfFilterDateValue(bill, PdfStatusFilter.released),
            fromDate: fromDate,
            toDate: toDate,
          );
    }).toList();
    final releasedCount = widget.account.bills
        .where((bill) => bill.status == EntryStatus.released)
        .length;

    return PageFrame(
      title: 'Released Bills',
      subtitle: '${releasedBills.length} released register lines',
      showBack: true,
      child: releasedCount == 0
          ? const EmptyState(
              icon: Icons.lock_open_outlined,
              title: 'No released bills',
              message: 'Released entries will appear here after release.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DateFilterField(
                        controller: _fromController,
                        label: 'From date',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DateFilterField(
                        controller: _toController,
                        label: 'To date',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    ActionChip(
                      label: const Text('Today'),
                      onPressed: _applyToday,
                    ),
                    ActionChip(
                      label: const Text('This month'),
                      onPressed: _applyThisMonth,
                    ),
                    ActionChip(
                      label: const Text('All released'),
                      onPressed: _clearFilter,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                RecordSearchField(
                  label: 'Search released bills',
                  suggestions: _releasedBillSuggestions(widget.account),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                if (releasedBills.isEmpty)
                  const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No matching released bills',
                    message:
                        'Search by bill no, date, release date, customer, area, jewels, amount, weight, or status.',
                  )
                else
                  for (final bill in releasedBills) ...<Widget>[
                    RegisterPreviewLine(
                      bill: bill,
                      onEdit: widget.account.isOwner
                          ? () => _editBill(bill)
                          : null,
                      onDelete: widget.account.isOwner
                          ? () => _deleteBill(bill)
                          : null,
                      isDeleting: _deletingBillIds.contains(bill.id),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final customers = widget.account.customers.where((customer) {
      final text =
          '${customer.name} ${customer.fatherOrHusbandName} ${customer.areaName} ${customer.streetName} ${customer.mobileNumber}'
              .toLowerCase();
      return normalized.isNotEmpty && text.contains(normalized);
    }).toList();
    final bills = widget.account.bills.where((bill) {
      final text =
          '${bill.billNo} ${bill.date} ${bill.customerName} ${bill.areaName} ${bill.jewels} ${bill.amount} ${bill.weight} ${bill.status.label}'
              .toLowerCase();
      return normalized.isNotEmpty && text.contains(normalized);
    }).toList();
    final releases = widget.account.releases.where((release) {
      final text =
          '${release.billNo} ${release.releaseDate} ${release.customerName} ${release.jewels} ${release.amount} ${release.weight} ${release.releasedBy}'
              .toLowerCase();
      return normalized.isNotEmpty && text.contains(normalized);
    }).toList();
    final hasResults =
        customers.isNotEmpty || bills.isNotEmpty || releases.isNotEmpty;

    return PageFrame(
      title: 'Search',
      subtitle: 'All modules',
      showBack: true,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: <Widget>[
          RecordSearchField(
            label: 'Search all records',
            suggestions: _allRecordSuggestions(widget.account),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 16),
          if (normalized.isEmpty)
            const EmptyState(
              icon: Icons.search_rounded,
              title: 'Search every module',
              message:
                  'Type bill no, customer name, mobile, area, jewels, amount, weight, or status.',
            )
          else if (!hasResults)
            const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matching records',
              message:
                  'No customer, bill, or release record matched this search.',
            )
          else ...<Widget>[
            if (customers.isNotEmpty) ...<Widget>[
              SearchSectionTitle(title: 'Customer Bio Data'),
              for (final customer in customers) ...<Widget>[
                CustomerTile(customer: customer),
                const SizedBox(height: 10),
              ],
            ],
            if (bills.isNotEmpty) ...<Widget>[
              SearchSectionTitle(title: 'Daily Bills'),
              for (final bill in bills) ...<Widget>[
                RegisterPreviewLine(bill: bill),
                const SizedBox(height: 10),
              ],
            ],
            if (releases.isNotEmpty) ...<Widget>[
              SearchSectionTitle(title: 'Release Details'),
              for (final release in releases) ...<Widget>[
                ReleaseTile(release: release),
                const SizedBox(height: 10),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

class PdfScreen extends StatefulWidget {
  const PdfScreen({super.key, required this.account});

  final BusinessAccount account;

  @override
  State<PdfScreen> createState() => _PdfScreenState();
}

class _PdfScreenState extends State<PdfScreen> {
  late final TextEditingController _fromController;
  late final TextEditingController _toController;
  final Set<String> _selectedPdfBillIds = <String>{};
  PdfStatusFilter _statusFilter = PdfStatusFilter.all;
  String _query = '';
  bool _isGenerating = false;
  bool _selectionInitialized = false;

  @override
  void initState() {
    super.initState();
    _fromController = TextEditingController();
    _toController = TextEditingController(
      text: _formatRegisterDate(DateTime.now()),
    );
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _applyToday() {
    final today = _formatRegisterDate(DateTime.now());
    setState(() {
      _fromController.text = today;
      _toController.text = today;
      _selectionInitialized = false;
    });
  }

  void _applyThisMonth() {
    final now = DateTime.now();
    setState(() {
      _fromController.text = _formatRegisterDate(DateTime(now.year, now.month));
      _toController.text = _formatRegisterDate(now);
      _selectionInitialized = false;
    });
  }

  void _clearFilter() {
    setState(() {
      _fromController.clear();
      _toController.clear();
      _statusFilter = PdfStatusFilter.all;
      _query = '';
      _selectionInitialized = false;
    });
  }

  void _filterChanged() {
    setState(() => _selectionInitialized = false);
  }

  void _changeStatusFilter(PdfStatusFilter filter) {
    setState(() {
      _statusFilter = filter;
      _selectionInitialized = false;
    });
  }

  void _changeSearch(String value) {
    setState(() {
      _query = value;
      _selectionInitialized = false;
    });
  }

  void _selectAllShown(List<BillEntry> bills) {
    setState(() {
      _selectedPdfBillIds
        ..clear()
        ..addAll(bills.map((bill) => bill.id));
      _selectionInitialized = true;
    });
  }

  void _clearSelected() {
    setState(() {
      _selectedPdfBillIds.clear();
      _selectionInitialized = true;
    });
  }

  void _togglePdfSelection(BillEntry bill, bool selected) {
    setState(() {
      if (selected) {
        _selectedPdfBillIds.add(bill.id);
      } else {
        _selectedPdfBillIds.remove(bill.id);
      }
      _selectionInitialized = true;
    });
  }

  Future<void> _sharePdf(List<BillEntry> bills) async {
    if (bills.isEmpty) {
      _showMessage('No entries for PDF');
      return;
    }

    setState(() => _isGenerating = true);
    try {
      final bytes = await RegisterPdfGenerator.build(bills: bills);
      await Printing.sharePdf(bytes: bytes, filename: _pdfFileName());
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to generate PDF');
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _savePdfFile(List<BillEntry> bills) async {
    if (bills.isEmpty) {
      _showMessage('No entries for PDF');
      return;
    }

    setState(() => _isGenerating = true);
    try {
      final bytes = await RegisterPdfGenerator.build(bills: bills);
      final saved = await PdfFileSaver.save(
        bytes: bytes,
        fileName: _pdfFileName(),
      );
      if (mounted) {
        _showMessage(saved ? 'PDF saved' : 'PDF save cancelled');
      }
    } on PlatformException catch (error) {
      if (mounted) {
        _showMessage(error.message ?? 'Unable to save PDF');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to save PDF');
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _printPdf(List<BillEntry> bills) async {
    if (bills.isEmpty) {
      _showMessage('No entries for PDF');
      return;
    }

    setState(() => _isGenerating = true);
    try {
      final bytes = await RegisterPdfGenerator.build(bills: bills);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to print PDF');
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _pdfFileName() {
    final date = _formatRegisterDate(DateTime.now()).replaceAll('.', '_');
    return 'psm_jewellers_${_statusFilter.fileNamePart}_register_$date.pdf';
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final fromDate = _parseRegisterDate(_fromController.text);
    final toDate = _parseRegisterDate(_toController.text);
    final exportBills = widget.account.bills.where((bill) {
      final text =
          '${bill.billNo} ${bill.date} ${bill.releaseDate} ${bill.customerName} ${bill.areaName} ${bill.jewels} ${bill.amount} ${bill.weight} ${bill.status.label}'
              .toLowerCase();
      final matchesSearch = normalized.isEmpty || text.contains(normalized);
      final matchesStatus = _statusFilter.matches(bill);
      final matchesDate = _isInsideDateRange(
        _pdfFilterDateValue(bill, _statusFilter),
        fromDate: fromDate,
        toDate: toDate,
      );
      return matchesSearch && matchesStatus && matchesDate;
    }).toList();
    if (!_selectionInitialized) {
      _selectedPdfBillIds
        ..clear()
        ..addAll(exportBills.map((bill) => bill.id));
      _selectionInitialized = true;
    }
    final visibleBillIds = exportBills.map((bill) => bill.id).toSet();
    _selectedPdfBillIds.removeWhere((id) => !visibleBillIds.contains(id));
    final selectedBills = exportBills
        .where((bill) => _selectedPdfBillIds.contains(bill.id))
        .toList();
    final pageCount = (selectedBills.length / 25).ceil();

    return PageFrame(
      title: 'Generate PDF',
      subtitle:
          '${_statusFilter.label} - ${selectedBills.length}/${exportBills.length} selected, ${pageCount == 0 ? 0 : pageCount} pages',
      showBack: true,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: DateFilterField(
                  controller: _fromController,
                  label: 'From date',
                  onChanged: (_) => _filterChanged(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DateFilterField(
                  controller: _toController,
                  label: 'To date',
                  onChanged: (_) => _filterChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: PdfStatusFilter.values.map((filter) {
              return ChoiceChip(
                label: Text(filter.label),
                selected: _statusFilter == filter,
                onSelected: (_) => _changeStatusFilter(filter),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ActionChip(label: const Text('Today'), onPressed: _applyToday),
              ActionChip(
                label: const Text('This month'),
                onPressed: _applyThisMonth,
              ),
              ActionChip(
                label: const Text('All entries'),
                onPressed: _clearFilter,
              ),
            ],
          ),
          const SizedBox(height: 14),
          RecordSearchField(
            label: 'Search PDF entries',
            suggestions: _billSuggestions(widget.account),
            onChanged: _changeSearch,
          ),
          const SizedBox(height: 20),
          Text(
            'PDF preview lines',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Chip(
                avatar: const Icon(Icons.check_box_outlined, size: 18),
                label: Text('${selectedBills.length} selected'),
              ),
              ActionChip(
                avatar: const Icon(Icons.select_all_rounded, size: 18),
                label: const Text('Select all shown'),
                onPressed: exportBills.isEmpty
                    ? null
                    : () => _selectAllShown(exportBills),
              ),
              ActionChip(
                avatar: const Icon(Icons.clear_rounded, size: 18),
                label: const Text('Clear'),
                onPressed: selectedBills.isEmpty ? null : _clearSelected,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.account.bills.isEmpty)
            const EmptyState(
              icon: Icons.picture_as_pdf_outlined,
              title: 'No entries to export',
              message: 'Create entries before generating PDF.',
            )
          else if (exportBills.isEmpty)
            const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matching PDF entries',
              message:
                  'Search by bill no, customer, date, release date, jewels, amount, weight, or status.',
            )
          else
            for (final bill in exportBills) ...<Widget>[
              RegisterPreviewLine(
                bill: bill,
                isSelected: _selectedPdfBillIds.contains(bill.id),
                onSelectionChanged: (selected) =>
                    _togglePdfSelection(bill, selected),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _isGenerating || selectedBills.isEmpty
                ? null
                : () => _sharePdf(selectedBills),
            icon: _isGenerating
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_rounded),
            label: Text(_isGenerating ? 'Generating...' : 'Share selected PDF'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _isGenerating || selectedBills.isEmpty
                ? null
                : () => _savePdfFile(selectedBills),
            icon: const Icon(Icons.save_alt_rounded),
            label: const Text('Save PDF file'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _isGenerating || selectedBills.isEmpty
                ? null
                : () => _printPdf(selectedBills),
            icon: const Icon(Icons.print_rounded),
            label: const Text('Print selected PDF'),
          ),
        ],
      ),
    );
  }
}

class RegisterPdfGenerator {
  static Future<Uint8List> build({required List<BillEntry> bills}) {
    final document = pw.Document();
    final pages = _chunkBills(bills, 25);
    final regularFont = pw.Font.times();

    for (final pageBills in pages) {
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(48, 42, 28, 28),
          build: (context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                for (final bill in pageBills)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 14),
                    child: pw.Text(
                      bill.registerLine,
                      style: pw.TextStyle(
                        font: regularFont,
                        fontSize: 13,
                        height: 1.15,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
    }

    return document.save();
  }

  static List<List<BillEntry>> _chunkBills(List<BillEntry> bills, int size) {
    final pages = <List<BillEntry>>[];
    for (var index = 0; index < bills.length; index += size) {
      final end = index + size > bills.length ? bills.length : index + size;
      pages.add(bills.sublist(index, end));
    }
    return pages;
  }
}

class PdfFileSaver {
  const PdfFileSaver._();

  static const MethodChannel _channel = MethodChannel(
    'psm_jewellers_app/pdf_file_saver',
  );

  static Future<bool> save({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }
    final saved = await _channel.invokeMethod<bool>('savePdfFile', {
      'fileName': fileName,
      'bytes': bytes,
    });
    return saved ?? false;
  }
}

String _formatRegisterDate(DateTime date) {
  return '${_twoDigits(date.day)}.${_twoDigits(date.month)}.${_twoDigits(date.year % 100)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _safeImageExtension(String fileName) {
  final lowerName = fileName.toLowerCase();
  final extension = lowerName.contains('.')
      ? lowerName.split('.').last.trim()
      : '';
  const allowedExtensions = <String>{'jpg', 'jpeg', 'png', 'webp'};
  return allowedExtensions.contains(extension) ? extension : 'jpg';
}

String _backupTimestamp(DateTime date) {
  return '${date.year}${_twoDigits(date.month)}${_twoDigits(date.day)}_'
      '${_twoDigits(date.hour)}${_twoDigits(date.minute)}${_twoDigits(date.second)}';
}

DateTime? _parseRegisterDate(String value) {
  final parts = value.trim().split('.');
  if (parts.length != 3) {
    return null;
  }

  final day = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final rawYear = int.tryParse(parts[2]);
  if (day == null || month == null || rawYear == null) {
    return null;
  }

  final year = rawYear < 100 ? 2000 + rawYear : rawYear;
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }

  final date = DateTime(year, month, day);
  if (date.day != day || date.month != month || date.year != year) {
    return null;
  }
  return date;
}

bool _isInsideDateRange(String value, {DateTime? fromDate, DateTime? toDate}) {
  if (fromDate == null && toDate == null) {
    return true;
  }

  final date = _parseRegisterDate(value);
  if (date == null) {
    return false;
  }

  if (fromDate != null && date.isBefore(_dateOnly(fromDate))) {
    return false;
  }
  if (toDate != null && date.isAfter(_dateOnly(toDate))) {
    return false;
  }
  return true;
}

String _pdfFilterDateValue(BillEntry bill, PdfStatusFilter filter) {
  if (filter == PdfStatusFilter.released && bill.releaseDate.isNotEmpty) {
    return bill.releaseDate;
  }
  return bill.date;
}

DateTime _dateOnly(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

Future<void> _releasePendingBill({
  required BuildContext context,
  required BusinessAccount account,
  required BillEntry bill,
  required Set<String> releasingBillIds,
  required StateSetter setScreenState,
}) async {
  if (bill.status == EntryStatus.released ||
      releasingBillIds.contains(bill.id)) {
    return;
  }

  final release = await _openReleaseDateSheet(
    context: context,
    account: account,
    bill: bill,
  );
  if (release == null || !context.mounted) {
    return;
  }

  setScreenState(() => releasingBillIds.add(bill.id));
  final stockItem = _stockItemForBill(account, bill);

  try {
    await account.releaseBill(
      bill: bill,
      stockItem: stockItem,
      release: release,
    );
  } on FirebaseException catch (error) {
    if (context.mounted) {
      setScreenState(() => releasingBillIds.remove(bill.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Firebase release failed')),
      );
    }
    return;
  } catch (_) {
    if (context.mounted) {
      setScreenState(() => releasingBillIds.remove(bill.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to release pending bill')),
      );
    }
    return;
  }

  if (!context.mounted) {
    return;
  }

  setScreenState(() {
    releasingBillIds.remove(bill.id);
    bill.status = EntryStatus.released;
    bill.releaseDate = release.releaseDate;
    if (stockItem != null) {
      stockItem.status = StockStatus.released;
    }
    account.releases.add(release);
  });

  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('${bill.billNo} released')));
}

Future<ReleaseEntry?> _openReleaseDateSheet({
  required BuildContext context,
  required BusinessAccount account,
  required BillEntry bill,
}) async {
  final releaseDateController = TextEditingController(
    text: bill.releaseDate.isNotEmpty
        ? bill.releaseDate
        : _formatRegisterDate(DateTime.now()),
  );

  try {
    return await showModalBottomSheet<ReleaseEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: PsmColors.canvas,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            4,
            18,
            MediaQuery.of(sheetContext).viewInsets.bottom + 18,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Release Pending Bill',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '${bill.billNo} - ${bill.customerName}',
                style: Theme.of(sheetContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              DateFilterField(
                controller: releaseDateController,
                label: 'Release date',
                onChanged: (_) {},
              ),
              FilledButton.icon(
                onPressed: () {
                  final releaseDate = releaseDateController.text.trim();
                  if (_parseRegisterDate(releaseDate) == null) {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                      const SnackBar(
                        content: Text('Enter release date like 28.07.26'),
                      ),
                    );
                    return;
                  }

                  Navigator.of(sheetContext).pop(
                    ReleaseEntry(
                      id: 'rel_${DateTime.now().millisecondsSinceEpoch}',
                      billNo: bill.billNo,
                      releaseDate: releaseDate,
                      customerName: bill.customerName,
                      jewels: bill.jewels,
                      amount: bill.amount,
                      weight: bill.weight,
                      releasedBy: account.ownerName,
                    ),
                  );
                },
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text('Release bill'),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    releaseDateController.dispose();
  }
}

StockItem? _stockItemForBill(BusinessAccount account, BillEntry bill) {
  for (final item in account.stock) {
    if (item.billId == bill.id || item.billNo == bill.billNo) {
      return item;
    }
  }
  return null;
}

List<StockItem> _stockItemsForBill(BusinessAccount account, BillEntry bill) {
  return account.stock
      .where((item) => item.billId == bill.id || item.billNo == bill.billNo)
      .toList();
}

List<ReleaseEntry> _releaseEntriesForBill(
  BusinessAccount account,
  BillEntry bill,
) {
  return account.releases
      .where((release) => release.billNo == bill.billNo)
      .toList();
}

Future<void> _openBillEditSheet({
  required BuildContext context,
  required BusinessAccount account,
  required BillEntry bill,
  required StateSetter setScreenState,
}) async {
  final oldStockItems = _stockItemsForBill(account, bill);
  final oldReleases = _releaseEntriesForBill(account, bill);
  final billController = TextEditingController(text: bill.billNo);
  final dateController = TextEditingController(text: bill.date);
  final customerController = TextEditingController(text: bill.customerName);
  final areaController = TextEditingController(text: bill.areaName);
  final jewelsController = TextEditingController(text: bill.jewels);
  final amountController = TextEditingController(text: bill.amount.toString());
  final weightController = TextEditingController(text: bill.weight);
  final releaseDateController = TextEditingController(
    text: bill.releaseDate.isNotEmpty
        ? bill.releaseDate
        : _formatRegisterDate(DateTime.now()),
  );
  var status = bill.status;
  var isSaving = false;

  final customerSuggestions = _uniqueSuggestions(<String>[
    ...account.customers.map((customer) => customer.name),
    ...account.bills.map((entry) => entry.customerName),
  ]);
  final areaSuggestions = _uniqueSuggestions(<String>[
    ...account.customers.map((customer) => customer.areaName),
    ...account.bills.map((entry) => entry.areaName),
  ]);
  final jewelsSuggestions = _uniqueSuggestions(
    account.bills.map((entry) => entry.jewels),
  );
  final amountSuggestions = _uniqueSuggestions(
    account.bills.map((entry) => entry.amount.toString()),
  );
  final weightSuggestions = _uniqueSuggestions(
    account.bills.map((entry) => entry.weight),
  );

  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: PsmColors.canvas,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                4,
                18,
                MediaQuery.of(context).viewInsets.bottom + 18,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'Edit Bill Entry',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: billController,
                      label: 'Bill no',
                      icon: Icons.confirmation_number_outlined,
                    ),
                    DateFilterField(
                      controller: dateController,
                      label: 'Date',
                      onChanged: (_) {},
                    ),
                    AppTextField(
                      controller: customerController,
                      label: 'Customer name',
                      icon: Icons.person_outline_rounded,
                      suggestions: customerSuggestions,
                    ),
                    AppTextField(
                      controller: areaController,
                      label: 'Area name',
                      icon: Icons.location_on_outlined,
                      suggestions: areaSuggestions,
                    ),
                    AppTextField(
                      controller: jewelsController,
                      label: 'Jewels details',
                      icon: Icons.diamond_outlined,
                      suggestions: jewelsSuggestions,
                    ),
                    AppTextField(
                      controller: amountController,
                      label: 'Amount',
                      icon: Icons.currency_rupee_rounded,
                      keyboardType: TextInputType.number,
                      suggestions: amountSuggestions,
                    ),
                    AppTextField(
                      controller: weightController,
                      label: 'Weight',
                      icon: Icons.scale_outlined,
                      suggestions: weightSuggestions,
                    ),
                    DropdownButtonFormField<EntryStatus>(
                      initialValue: status,
                      items: EntryStatus.values
                          .map(
                            (entryStatus) => DropdownMenuItem<EntryStatus>(
                              value: entryStatus,
                              child: Text(entryStatus.label),
                            ),
                          )
                          .toList(),
                      onChanged: isSaving
                          ? null
                          : (entryStatus) {
                              if (entryStatus != null) {
                                setSheetState(() => status = entryStatus);
                              }
                            },
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        prefixIcon: Icon(Icons.fact_check_outlined),
                      ),
                    ),
                    if (status == EntryStatus.released) ...<Widget>[
                      const SizedBox(height: 12),
                      DateFilterField(
                        controller: releaseDateController,
                        label: 'Release date',
                        onChanged: (_) {},
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: isSaving
                          ? null
                          : () async {
                              final amount = int.tryParse(
                                amountController.text.trim(),
                              );
                              final entryDate = dateController.text.trim();
                              final releaseDate = releaseDateController.text
                                  .trim();
                              if (billController.text.trim().isEmpty ||
                                  customerController.text.trim().isEmpty ||
                                  areaController.text.trim().isEmpty ||
                                  jewelsController.text.trim().isEmpty ||
                                  amount == null ||
                                  weightController.text.trim().isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Enter all bill fields'),
                                  ),
                                );
                                return;
                              }
                              if (_parseRegisterDate(entryDate) == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Select a valid entry date'),
                                  ),
                                );
                                return;
                              }
                              if (status == EntryStatus.released &&
                                  _parseRegisterDate(releaseDate) == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Select a valid release date',
                                    ),
                                  ),
                                );
                                return;
                              }

                              final updatedBill = BillEntry(
                                id: bill.id,
                                billNo: billController.text.trim(),
                                date: entryDate,
                                customerName: customerController.text
                                    .trim()
                                    .toUpperCase(),
                                fatherOrHusbandName: '',
                                areaName: areaController.text
                                    .trim()
                                    .toUpperCase(),
                                jewels: jewelsController.text
                                    .trim()
                                    .toUpperCase(),
                                amount: amount,
                                weight: weightController.text
                                    .trim()
                                    .toUpperCase(),
                                status: status,
                                releaseDate: status == EntryStatus.released
                                    ? releaseDate
                                    : '',
                              );
                              final release = status == EntryStatus.released
                                  ? ReleaseEntry(
                                      id: oldReleases.isNotEmpty
                                          ? oldReleases.first.id
                                          : 'rel_${bill.id}',
                                      billNo: updatedBill.billNo,
                                      releaseDate: releaseDate,
                                      customerName: updatedBill.customerName,
                                      jewels: updatedBill.jewels,
                                      amount: updatedBill.amount,
                                      weight: updatedBill.weight,
                                      releasedBy: account.ownerName,
                                    )
                                  : null;

                              try {
                                final navigator = Navigator.of(sheetContext);
                                final messenger = ScaffoldMessenger.of(context);
                                setSheetState(() => isSaving = true);
                                await account.updateBillRecord(
                                  bill: updatedBill,
                                  stockItems: oldStockItems,
                                  oldReleases: oldReleases,
                                  release: release,
                                );
                                if (!context.mounted || !sheetContext.mounted) {
                                  return;
                                }

                                setScreenState(() {
                                  final billIndex = account.bills.indexWhere(
                                    (entry) => entry.id == updatedBill.id,
                                  );
                                  if (billIndex == -1) {
                                    account.bills.add(updatedBill);
                                  } else {
                                    account.bills[billIndex] = updatedBill;
                                  }

                                  final oldStockIds = oldStockItems
                                      .map((item) => item.id)
                                      .toSet();
                                  account.stock.removeWhere(
                                    (item) => oldStockIds.contains(item.id),
                                  );
                                  final stockItems = oldStockItems.isEmpty
                                      ? <StockItem>[
                                          StockItem(
                                            id: 'stock_${updatedBill.id}',
                                            billId: updatedBill.id,
                                            billNo: updatedBill.billNo,
                                            date: updatedBill.date,
                                            customerName:
                                                updatedBill.customerName,
                                            jewels: updatedBill.jewels,
                                            amount: updatedBill.amount,
                                            weight: updatedBill.weight,
                                            status:
                                                updatedBill.status.stockStatus,
                                          ),
                                        ]
                                      : oldStockItems
                                            .map(
                                              (item) => StockItem(
                                                id: item.id,
                                                billId:
                                                    item.billId ??
                                                    updatedBill.id,
                                                billNo: updatedBill.billNo,
                                                date: updatedBill.date,
                                                customerName:
                                                    updatedBill.customerName,
                                                jewels: updatedBill.jewels,
                                                amount: updatedBill.amount,
                                                weight: updatedBill.weight,
                                                status: updatedBill
                                                    .status
                                                    .stockStatus,
                                              ),
                                            )
                                            .toList();
                                  account.stock.addAll(stockItems);

                                  final oldReleaseIds = oldReleases
                                      .map((entry) => entry.id)
                                      .toSet();
                                  account.releases.removeWhere(
                                    (entry) => oldReleaseIds.contains(entry.id),
                                  );
                                  if (release != null) {
                                    account.releases.add(release);
                                  }
                                });

                                navigator.pop();
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${updatedBill.billNo} updated',
                                    ),
                                  ),
                                );
                              } on FirebaseException catch (error) {
                                if (!context.mounted || !sheetContext.mounted) {
                                  return;
                                }
                                setSheetState(() => isSaving = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      error.message ?? 'Firebase update failed',
                                    ),
                                  ),
                                );
                              } catch (_) {
                                if (!context.mounted || !sheetContext.mounted) {
                                  return;
                                }
                                setSheetState(() => isSaving = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Unable to update bill'),
                                  ),
                                );
                              }
                            },
                      icon: isSaving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(isSaving ? 'Saving...' : 'Update bill'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  } finally {
    billController.dispose();
    dateController.dispose();
    customerController.dispose();
    areaController.dispose();
    jewelsController.dispose();
    amountController.dispose();
    weightController.dispose();
    releaseDateController.dispose();
  }
}

Future<bool> _confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete'),
              ),
            ],
          );
        },
      ) ??
      false;
}

Future<void> _deleteCustomerRecord({
  required BuildContext context,
  required BusinessAccount account,
  required CustomerProfile customer,
  required Set<String> deletingCustomerIds,
  required StateSetter setScreenState,
}) async {
  final confirmed = await _confirmDelete(
    context,
    title: 'Delete customer?',
    message:
        '${customer.name} Bio Data will be deleted. This will not delete bills.',
  );
  if (!confirmed || !context.mounted) {
    return;
  }

  setScreenState(() => deletingCustomerIds.add(customer.id));
  try {
    await account.deleteCustomer(customer);
  } on FirebaseException catch (error) {
    if (context.mounted) {
      setScreenState(() => deletingCustomerIds.remove(customer.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Firebase delete failed')),
      );
    }
    return;
  } catch (_) {
    if (context.mounted) {
      setScreenState(() => deletingCustomerIds.remove(customer.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to delete customer')),
      );
    }
    return;
  }

  if (!context.mounted) {
    return;
  }
  setScreenState(() {
    deletingCustomerIds.remove(customer.id);
    account.customers.removeWhere((item) => item.id == customer.id);
  });
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('${customer.name} deleted')));
}

Future<void> _deleteBillRecord({
  required BuildContext context,
  required BusinessAccount account,
  required BillEntry bill,
  required Set<String> deletingBillIds,
  required StateSetter setScreenState,
}) async {
  final confirmed = await _confirmDelete(
    context,
    title: 'Delete bill?',
    message:
        '${bill.billNo} will be deleted from Daily Bills. Linked stock and release details will also be deleted.',
  );
  if (!confirmed || !context.mounted) {
    return;
  }

  setScreenState(() => deletingBillIds.add(bill.id));
  final stockItems = _stockItemsForBill(account, bill);
  final releases = _releaseEntriesForBill(account, bill);

  try {
    await account.deleteBillRecord(
      bill: bill,
      stockItems: stockItems,
      releases: releases,
    );
  } on FirebaseException catch (error) {
    if (context.mounted) {
      setScreenState(() => deletingBillIds.remove(bill.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Firebase delete failed')),
      );
    }
    return;
  } catch (_) {
    if (context.mounted) {
      setScreenState(() => deletingBillIds.remove(bill.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to delete bill')));
    }
    return;
  }

  if (!context.mounted) {
    return;
  }
  final stockIds = stockItems.map((item) => item.id).toSet();
  final releaseIds = releases.map((release) => release.id).toSet();
  setScreenState(() {
    deletingBillIds.remove(bill.id);
    account.bills.removeWhere((item) => item.id == bill.id);
    account.stock.removeWhere((item) => stockIds.contains(item.id));
    account.releases.removeWhere((release) => releaseIds.contains(release.id));
  });
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('${bill.billNo} deleted')));
}

class MoreScreen extends StatelessWidget {
  const MoreScreen({
    super.key,
    required this.account,
    required this.user,
    required this.onSwitchAccount,
    required this.onSignOut,
    required this.onOpenBills,
    required this.onOpenPending,
    required this.onOpenRelease,
    required this.onOpenPdf,
    required this.onOpenSearch,
  });

  final BusinessAccount account;
  final AppUser user;
  final VoidCallback onSwitchAccount;
  final VoidCallback onSignOut;
  final VoidCallback onOpenBills;
  final VoidCallback onOpenPending;
  final VoidCallback onOpenRelease;
  final VoidCallback onOpenPdf;
  final VoidCallback onOpenSearch;

  Future<void> _shareBiodataBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing Bio Data backup...')),
    );

    try {
      final backupFile = await account.createBiodataBackup();
      if (!context.mounted) {
        return;
      }
      messenger.hideCurrentSnackBar();
      await share_plus.SharePlus.instance.share(
        share_plus.ShareParams(
          title: 'P S M Jewellers Bio Data Backup',
          text: 'P S M Jewellers Bio Data backup. Choose Google Drive to save.',
          files: <share_plus.XFile>[
            share_plus.XFile(backupFile.path, mimeType: 'application/zip'),
          ],
        ),
      );
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('Unable to create Bio Data backup')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'More',
      subtitle: account.shopName,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  const BrandMark(size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          account.shopName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${user.email} - ${account.role.label}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (account.isOwner) ...<Widget>[
            MoreTile(
              icon: Icons.search_rounded,
              title: 'Search records',
              subtitle: 'Find bills, customers, area, and date',
              onTap: onOpenSearch,
            ),
            MoreTile(
              icon: Icons.receipt_long_rounded,
              title: 'Daily bills',
              subtitle: 'View register lines',
              onTap: onOpenBills,
            ),
            MoreTile(
              icon: Icons.pending_actions_rounded,
              title: 'Pending bills',
              subtitle: 'Release pending register entries',
              onTap: onOpenPending,
            ),
            MoreTile(
              icon: Icons.lock_open_rounded,
              title: 'Released bills',
              subtitle: 'View closed register entries',
              onTap: onOpenRelease,
            ),
            MoreTile(
              icon: Icons.picture_as_pdf_rounded,
              title: 'Generate PDF',
              subtitle: 'Date filter and export',
              onTap: onOpenPdf,
            ),
            MoreTile(
              icon: Icons.drive_folder_upload_outlined,
              title: 'Backup Bio Data',
              subtitle: 'Share local photos ZIP to Google Drive',
              onTap: () => _shareBiodataBackup(context),
            ),
            MoreTile(
              icon: Icons.group_rounded,
              title: 'Owner account',
              subtitle: 'Owner-only Firebase access',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('This app uses owner-only login'),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onSwitchAccount,
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('Switch account'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onSignOut,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
    this.showBack = false,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title),
            Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        actions: trailing == null ? null : <Widget>[trailing!],
      ),
      body: child,
    );
  }
}

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.caption,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: PsmColors.goldSoft,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: PsmColors.goldDeep),
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CustomerTile extends StatelessWidget {
  const CustomerTile({
    super.key,
    required this.customer,
    this.onEdit,
    this.onDelete,
    this.isDeleting = false,
  });

  final CustomerProfile customer;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        minVerticalPadding: 14,
        leading: CustomerAvatar(customer: customer),
        title: Text(
          customer.name,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          '${customer.fatherOrHusbandName} - ${customer.areaName}\n${customer.streetName} - ${customer.mobileNumber}',
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              customer.hasImage
                  ? Icons.image_rounded
                  : Icons.image_not_supported,
              color: customer.hasImage ? PsmColors.forest : PsmColors.muted,
            ),
            if (onEdit != null) ...<Widget>[
              const SizedBox(width: 4),
              IconButton(
                onPressed: isDeleting ? null : onEdit,
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit customer',
              ),
            ],
            if (onDelete != null) ...<Widget>[
              const SizedBox(width: 4),
              isDeleting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: 'Delete customer',
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

class CustomerAvatar extends StatelessWidget {
  const CustomerAvatar({super.key, required this.customer});

  final CustomerProfile customer;

  @override
  Widget build(BuildContext context) {
    ImageProvider<Object>? photoProvider;
    final localPhotoPath = customer.localPhotoPath;
    if (localPhotoPath.isNotEmpty && File(localPhotoPath).existsSync()) {
      photoProvider = FileImage(File(localPhotoPath));
    } else if (customer.imageUrl.isNotEmpty) {
      photoProvider = NetworkImage(customer.imageUrl);
    }

    return CircleAvatar(
      radius: 25,
      backgroundColor: customer.hasImage
          ? PsmColors.goldSoft
          : const Color(0xFFECE6D6),
      backgroundImage: photoProvider,
      child: photoProvider != null
          ? null
          : customer.hasImage
          ? const Icon(Icons.person_rounded, color: PsmColors.goldDeep)
          : Text(
              customer.initials,
              style: const TextStyle(
                color: PsmColors.forest,
                fontWeight: FontWeight.w900,
              ),
            ),
    );
  }
}

class ReleaseTile extends StatelessWidget {
  const ReleaseTile({
    super.key,
    required this.release,
    this.onDelete,
    this.isDeleting = false,
  });

  final ReleaseEntry release;
  final VoidCallback? onDelete;
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.lock_open_rounded),
        title: Text('${release.billNo} - ${release.customerName}'),
        subtitle: Text(
          '${release.releaseDate} - ${release.jewels} - ${release.weight}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(MoneyText.format(release.amount)),
            if (onDelete != null) ...<Widget>[
              const SizedBox(width: 4),
              isDeleting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: 'Delete release',
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

class RegisterPreviewLine extends StatelessWidget {
  const RegisterPreviewLine({
    super.key,
    required this.bill,
    this.onRelease,
    this.isReleasing = false,
    this.onEdit,
    this.onDelete,
    this.isDeleting = false,
    this.isSelected,
    this.onSelectionChanged,
  });

  final BillEntry bill;
  final VoidCallback? onRelease;
  final bool isReleasing;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool isDeleting;
  final bool? isSelected;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final selectable = onSelectionChanged != null;
    final selected = isSelected ?? false;
    return Card(
      color: selectable && selected
          ? PsmColors.goldSoft.withValues(alpha: 0.34)
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: selectable ? () => onSelectionChanged!(!selected) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (selectable) ...<Widget>[
                    SizedBox(
                      width: 34,
                      child: Checkbox(
                        value: selected,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: isDeleting || isReleasing
                            ? null
                            : (value) => onSelectionChanged!(value ?? false),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  SizedBox(
                    width: 76,
                    child: Text(
                      bill.billNo,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  EntryStatusChip(status: bill.status),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      MoneyText.format(bill.amount),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: PsmColors.forest,
                      ),
                    ),
                  ),
                  if (onEdit != null) ...<Widget>[
                    const SizedBox(width: 4),
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      onPressed: isDeleting || isReleasing ? null : onEdit,
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit bill',
                    ),
                  ],
                  if (onDelete != null) ...<Widget>[
                    const SizedBox(width: 4),
                    isDeleting
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            constraints: const BoxConstraints.tightFor(
                              width: 38,
                              height: 38,
                            ),
                            onPressed: onDelete,
                            icon: const Icon(Icons.delete_outline_rounded),
                            tooltip: 'Delete bill',
                          ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                bill.registerLine,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: PsmColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (bill.releaseDate.isNotEmpty &&
                  bill.status == EntryStatus.released) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Released on ${bill.releaseDate}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              if (bill.status == EntryStatus.pending &&
                  onRelease != null) ...<Widget>[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: isReleasing || isDeleting ? null : onRelease,
                    icon: isReleasing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_rounded),
                    label: Text(isReleasing ? 'Releasing...' : 'Release'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EntryStatusChip extends StatelessWidget {
  const EntryStatusChip({super.key, required this.status});

  final EntryStatus status;

  @override
  Widget build(BuildContext context) {
    final isPending = status == EntryStatus.pending;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: isPending ? const Color(0xFFFFF3C7) : const Color(0xFFE8F1E5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: isPending ? PsmColors.goldDeep : PsmColors.forest,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class MetricPill extends StatelessWidget {
  const MetricPill({
    super.key,
    required this.title,
    required this.value,
    this.light = false,
  });

  final String title;
  final String value;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: light ? Colors.white.withValues(alpha: 0.16) : PsmColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: light ? Colors.white.withValues(alpha: 0.22) : PsmColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              color: light ? Colors.white : PsmColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: light ? const Color(0xFFFFF8E5) : PsmColors.muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class MiniChip extends StatelessWidget {
  const MiniChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: PsmColors.goldSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: PsmColors.forest,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final StockStatus status;

  @override
  Widget build(BuildContext context) {
    final isPresent = status == StockStatus.present;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isPresent ? const Color(0xFFE8F1E5) : const Color(0xFFF3E4E4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: isPresent ? PsmColors.forest : PsmColors.danger,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class DateFilterField extends StatelessWidget {
  const DateFilterField({
    super.key,
    required this.controller,
    required this.label,
    required this.onChanged,
    this.allowManualEdit = false,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String> onChanged;
  final bool allowManualEdit;

  Future<void> _pickDate(BuildContext context) async {
    final currentDate = _parseRegisterDate(controller.text) ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: label,
      cancelText: 'Cancel',
      confirmText: 'Select',
    );
    if (pickedDate == null) {
      return;
    }

    final formattedDate = _formatRegisterDate(pickedDate);
    controller.text = formattedDate;
    onChanged(formattedDate);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: !allowManualEdit,
      keyboardType: TextInputType.datetime,
      onTap: () => _pickDate(context),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'dd.mm.yy',
        prefixIcon: const Icon(Icons.calendar_today_outlined),
        suffixIcon: IconButton(
          tooltip: 'Choose date',
          icon: const Icon(Icons.event_rounded),
          onPressed: () => _pickDate(context),
        ),
      ),
    );
  }
}

class FilterBox extends StatelessWidget {
  const FilterBox({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Icon(Icons.calendar_today_outlined, size: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MoreTile extends StatelessWidget {
  const MoreTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          leading: Icon(icon, color: PsmColors.goldDeep),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}

class ErrorStrip extends StatelessWidget {
  const ErrorStrip({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8E7E7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE7B9B9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline_rounded, color: PsmColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: PsmColors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: PsmColors.goldSoft,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, color: PsmColors.goldDeep, size: 34),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 18),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class RecordSearchField extends StatelessWidget {
  const RecordSearchField({
    super.key,
    required this.label,
    required this.onChanged,
    this.suggestions = const <String>[],
  });

  final String label;
  final ValueChanged<String> onChanged;
  final List<String> suggestions;

  @override
  Widget build(BuildContext context) {
    return SuggestionTextField(
      label: label,
      icon: Icons.search_rounded,
      suggestions: suggestions,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      suffixIcon: const Icon(Icons.tune_rounded, size: 18),
    );
  }
}

class SearchSectionTitle extends StatelessWidget {
  const SearchSectionTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.suggestions = const <String>[],
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<String> suggestions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SuggestionTextField(
        controller: controller,
        label: label,
        icon: icon,
        keyboardType: keyboardType,
        suggestions: suggestions,
      ),
    );
  }
}

class SuggestionTextField extends StatefulWidget {
  const SuggestionTextField({
    super.key,
    required this.label,
    required this.icon,
    this.controller,
    this.keyboardType,
    this.suggestions = const <String>[],
    this.onChanged,
    this.textInputAction,
    this.suffixIcon,
  });

  final TextEditingController? controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<String> suggestions;
  final ValueChanged<String>? onChanged;
  final TextInputAction? textInputAction;
  final Widget? suffixIcon;

  @override
  State<SuggestionTextField> createState() => _SuggestionTextFieldState();
}

class _SuggestionTextFieldState extends State<SuggestionTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _controller,
      focusNode: _focusNode,
      displayStringForOption: (option) => option,
      optionsBuilder: (value) {
        final options = _suggestionMatches(widget.suggestions, value.text);
        return options;
      },
      onSelected: (value) {
        _controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        widget.onChanged?.call(value);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: Icon(widget.icon),
            suffixIcon: widget.suffixIcon,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            color: PsmColors.surface,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 340),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                itemCount: options.length,
                separatorBuilder: (context, index) =>
                    const Divider(height: 1, color: PsmColors.line),
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.history_rounded,
                      color: PsmColors.goldDeep,
                    ),
                    title: Text(
                      option,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

List<String> _customerSuggestions(BusinessAccount account) {
  return _uniqueSuggestions(
    account.customers.expand(
      (customer) => <String>[
        customer.name,
        customer.fatherOrHusbandName,
        customer.areaName,
        customer.streetName,
        customer.mobileNumber,
      ],
    ),
  );
}

List<String> _billSuggestions(BusinessAccount account) {
  return _uniqueSuggestions(
    account.bills.expand(
      (bill) => <String>[
        bill.billNo,
        bill.date,
        bill.releaseDate,
        bill.customerName,
        bill.areaName,
        bill.jewels,
        bill.amount.toString(),
        bill.weight,
        bill.status.label,
      ],
    ),
  );
}

List<String> _pendingBillSuggestions(BusinessAccount account) {
  return _uniqueSuggestions(
    account.bills
        .where((bill) => bill.status == EntryStatus.pending)
        .expand(
          (bill) => <String>[
            bill.billNo,
            bill.date,
            bill.customerName,
            bill.areaName,
            bill.jewels,
            bill.amount.toString(),
            bill.weight,
          ],
        ),
  );
}

List<String> _releasedBillSuggestions(BusinessAccount account) {
  return _uniqueSuggestions(
    account.bills
        .where((bill) => bill.status == EntryStatus.released)
        .expand(
          (bill) => <String>[
            bill.billNo,
            bill.date,
            bill.releaseDate,
            bill.customerName,
            bill.areaName,
            bill.jewels,
            bill.amount.toString(),
            bill.weight,
            bill.status.label,
          ],
        ),
  );
}

List<String> _releaseSuggestions(BusinessAccount account) {
  return _uniqueSuggestions(
    account.releases.expand(
      (release) => <String>[
        release.billNo,
        release.releaseDate,
        release.customerName,
        release.jewels,
        release.amount.toString(),
        release.weight,
        release.releasedBy,
      ],
    ),
  );
}

List<String> _allRecordSuggestions(BusinessAccount account) {
  return _uniqueSuggestions(<String>[
    ..._customerSuggestions(account),
    ..._billSuggestions(account),
    ..._releaseSuggestions(account),
  ]);
}

Iterable<String> _suggestionMatches(List<String> suggestions, String query) {
  final normalized = query.trim().toLowerCase();
  final unique = _uniqueSuggestions(suggestions);
  if (normalized.isEmpty) {
    return unique.take(5);
  }
  return unique
      .where((item) => item.toLowerCase().contains(normalized))
      .take(6);
}

List<String> _uniqueSuggestions(Iterable<String> values) {
  final seen = <String>{};
  final suggestions = <String>[];
  for (final value in values) {
    final clean = value.trim();
    if (clean.isEmpty) {
      continue;
    }
    final key = clean.toLowerCase();
    if (seen.add(key)) {
      suggestions.add(clean);
    }
  }
  return suggestions;
}
