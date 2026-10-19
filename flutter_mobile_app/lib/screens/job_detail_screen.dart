import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/job_detail.dart';
import '../services/jobs_service.dart';
import '../services/tasks_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_surface_card.dart';
import '../widgets/priority_badge.dart';
import '../widgets/status_pill.dart';

class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({
    super.key,
    required this.jobCode,
    required this.jobsService,
    this.tasksService,
  });

  final String jobCode;
  final JobsService jobsService;
  final TasksService? tasksService;

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  JobDetail? _currentDetail;
  bool _isBackgroundSyncing = false;
  String? _errorMessage;

  final TextEditingController _notesController = TextEditingController();

  bool _isActionBusy = false;
  bool _isNotesSaving = false;
  bool _isServiceBusy = false;
  bool _isEditingNotes = false;
  bool _isChecklistSaving = false;

  Map<String, dynamic> _checklistAnswers = {};
  bool _checklistInitialized = false;

  bool get _isBusy =>
      _isActionBusy || _isNotesSaving || _isServiceBusy || _isChecklistSaving;

  bool get _isTechnician {
    final role = (widget.jobsService.authService.currentUser?['role'] ?? '')
        .toString()
        .toLowerCase();
    return role == 'technician';
  }

  @override
  void initState() {
    super.initState();
    // 0ms instant cached render
    _currentDetail = widget.jobsService.getCachedJobDetail(widget.jobCode);
    if (_currentDetail != null) {
      _syncNotesController(_currentDetail!);
      _syncChecklistAnswers(_currentDetail!);
    }
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    if (!mounted) return;
    setState(() {
      _isBackgroundSyncing = true;
      _errorMessage = null;
    });

    try {
      final detail = await widget.jobsService.fetchJobDetail(widget.jobCode);
      if (mounted) {
        setState(() {
          _currentDetail = detail;
          _isBackgroundSyncing = false;
        });
        _syncNotesController(detail);
        _syncChecklistAnswers(detail);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isBackgroundSyncing = false;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _syncNotesController(JobDetail detail) {
    if (_isEditingNotes) {
      return;
    }
    final remoteNotes = detail.technicianNotes;
    if (_notesController.text != remoteNotes) {
      _notesController.text = remoteNotes;
    }
  }

  void _syncChecklistAnswers(JobDetail detail) {
    if (_checklistInitialized) {
      return;
    }
    _checklistAnswers = Map<String, dynamic>.from(detail.checklistAnswers);
    // Also pull initial values from schema if not present in answers
    for (final field in detail.checklistSchema) {
      if (!_checklistAnswers.containsKey(field.key) && field.value != null) {
        _checklistAnswers[field.key] = field.value;
      }
    }
    _checklistInitialized = true;
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.warningFg,
        content: Text(message),
      ),
    );
  }

  void _showInfo(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _refresh() async {
    _checklistInitialized = false;
    await _loadDetail();
  }

  Future<void> _makeCall(String phoneNumber) async {
    final clean = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    if (clean.isEmpty) {
      _showError('No customer phone number available.');
      return;
    }
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return;
      }
      final launched = await launchUrl(uri);
      if (!launched) {
        _copyToClipboard(clean, 'Phone Number');
        _showError('Unable to open phone dialer. Number copied to clipboard.');
      }
    } catch (_) {
      _copyToClipboard(clean, 'Phone Number');
      _showError('Unable to open phone dialer. Number copied to clipboard.');
    }
  }

  Future<void> _openWhatsApp(String phoneNumber) async {
    var digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) {
      _showError('No customer phone number available.');
      return;
    }
    if (digits.length == 10) {
      digits = '91$digits';
    }

    // Try 1: Native WhatsApp app intent scheme (opens WhatsApp app directly)
    final nativeUri = Uri.parse('whatsapp://send?phone=$digits');
    try {
      if (await canLaunchUrl(nativeUri)) {
        final ok = await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
        if (ok) return;
      }
    } catch (_) {}

    // Try 2: Universal wa.me link (handled by WhatsApp app or browser)
    final webUri = Uri.parse('https://wa.me/$digits');
    try {
      if (await canLaunchUrl(webUri)) {
        final ok = await launchUrl(webUri, mode: LaunchMode.externalApplication);
        if (ok) return;
      }
    } catch (_) {}

    // Try 3: Direct launch without pre-checking canLaunchUrl (bypasses OEM restrictions)
    try {
      final ok = await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}

    try {
      final ok = await launchUrl(webUri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}

    // Fallback: Copy to clipboard and inform user
    _copyToClipboard(digits, 'Customer WhatsApp Number');
    _showError('WhatsApp not detected. Number copied to clipboard.');
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _showInfo('$label copied to clipboard');
  }

  Future<void> _runAction(JobActionOption action, {JobDetail? detail}) async {
    // If completing the job, validate required checklist fields locally first
    if (action.key == 'complete' && detail != null && detail.checklistSchema.isNotEmpty) {
      final missingRequired = <String>[];
      for (final field in detail.checklistSchema) {
        if (!field.required) continue;
        final val = _checklistAnswers[field.key];
        if (field.type == 'checkbox') {
          if (val != true && val != 'true' && val != 1) {
            missingRequired.add(field.label);
          }
        } else {
          if (val == null || val.toString().trim().isEmpty) {
            missingRequired.add(field.label);
          }
        }
      }

      if (missingRequired.isNotEmpty) {
        _showError(
          'Please complete required tests before finishing: ${missingRequired.take(3).join(', ')}${missingRequired.length > 3 ? '...' : ''}',
        );
        return;
      }
    }

    setState(() {
      _isActionBusy = true;
    });
    try {
      final message = await widget.jobsService.performJobAction(
        jobCode: widget.jobCode,
        action: action.key,
        answers: action.key == 'complete' ? _checklistAnswers : null,
      );
      _showInfo(message);
      await _refresh();
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isActionBusy = false;
        });
      }
    }
  }

  void _showAllActionsSheet(JobDetail detail) {
    final actions = detail.availableActions;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Workflow Actions',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...actions.map((act) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          _runAction(act, detail: detail);
                        },
                        icon: const Icon(Icons.bolt_rounded, size: 20),
                        label: Text(act.label),
                        style: FilledButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveNotes(JobDetail detail) async {
    if (!detail.canEditNotes || _isNotesSaving) {
      return;
    }
    setState(() {
      _isNotesSaving = true;
    });
    try {
      final message = await widget.jobsService.updateJobNotes(
        jobCode: widget.jobCode,
        technicianNotes: _notesController.text.trim(),
      );
      _showInfo(message);
      if (!mounted) {
        return;
      }
      setState(() {
        _isEditingNotes = false;
      });
      await _refresh();
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isNotesSaving = false;
        });
      }
    }
  }

  Future<void> _saveChecklist() async {
    if (_isChecklistSaving) {
      return;
    }
    setState(() {
      _isChecklistSaving = true;
    });
    try {
      final message = await widget.jobsService.saveJobChecklist(
        jobCode: widget.jobCode,
        answers: _checklistAnswers,
      );
      _showInfo(message);
      await _refresh();
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isChecklistSaving = false;
        });
      }
    }
  }

  Future<void> _openServiceLineEditor({JobServiceLine? line}) async {
    final result = await showModalBottomSheet<_ServiceLineInput>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ServiceLineEditorSheet(initialLine: line),
    );
    if (result == null) {
      return;
    }

    setState(() {
      _isServiceBusy = true;
    });
    try {
      final message = line == null
          ? await widget.jobsService.addServiceLine(
              jobCode: widget.jobCode,
              description: result.description,
              partCost: result.partCost,
              serviceCharge: result.serviceCharge,
              salesInvoiceNumber: result.salesInvoiceNumber,
            )
          : await widget.jobsService.updateServiceLine(
              jobCode: widget.jobCode,
              lineId: line.id,
              description: result.description,
              partCost: result.partCost,
              serviceCharge: result.serviceCharge,
              salesInvoiceNumber: result.salesInvoiceNumber,
            );
      _showInfo(message);
      await _refresh();
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isServiceBusy = false;
        });
      }
    }
  }

  Future<void> _deleteServiceLine(JobServiceLine line) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Service Line'),
        content: Text('Delete "${line.description}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _isServiceBusy = true;
    });
    try {
      final message = await widget.jobsService.deleteServiceLine(
        jobCode: widget.jobCode,
        lineId: line.id,
      );
      _showInfo(message);
      await _refresh();
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isServiceBusy = false;
        });
      }
    }
  }

  Future<void> _openChangeRackSheet(JobDetail detail) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ChangeRackSheet(
        jobCode: detail.jobCode,
        currentRackId: detail.rackId,
        currentColumn: detail.rackColumn,
        availableRacks: detail.availableRacks,
        jobsService: widget.jobsService,
      ),
    );
    if (result == true) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _currentDetail;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.jobCode),
        bottom: _isBackgroundSyncing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: AppColors.primary,
                ),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: (_isBusy || _isBackgroundSyncing) ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: detail == null
          ? (_errorMessage != null
              ? _buildErrorView(_errorMessage!)
              : _buildSkeletonLoader())
          : _buildDetailContent(detail),
    );
  }

  Widget _buildErrorView(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.warningFg),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _refresh,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonLoader() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Container(
          height: 130,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 100,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailContent(JobDetail detail) {
    final isJobFinished = const {'Completed', 'Ready for Pickup', 'Closed'}
        .contains(detail.status);

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              14,
              12,
              14,
              detail.availableActions.isNotEmpty ? 100 : 32,
            ),
            children: [
              _buildHeroCard(detail),
              if (isJobFinished) ...[
                const SizedBox(height: 12),
                _buildCompletedHeroBanner(detail),
              ],
              const SizedBox(height: 12),
              _buildDeviceStorageCard(detail),
              const SizedBox(height: 12),
              _buildReportedIssueCard(detail),
              if (detail.checklistSchema.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildChecklistCard(detail),
              ],
              const SizedBox(height: 12),
              _buildTasksCard(detail),
              const SizedBox(height: 12),
              _buildServiceLinesCard(detail),
              if (!_isTechnician) ...[
                const SizedBox(height: 12),
                _buildFinancialSummaryCard(detail),
              ],
              const SizedBox(height: 12),
              _buildTechnicianNotesCard(detail),
              if (detail.feedbackRating > 0 ||
                  detail.feedbackComment.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildFeedbackCard(detail),
              ],
            ],
          ),
        ),
        if (detail.availableActions.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildStickyActionBar(detail),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION BUILDERS
  // ---------------------------------------------------------------------------

  Widget _buildHeroCard(JobDetail detail) {
    final deviceTitle =
        '${detail.deviceBrand} ${detail.deviceModel}'.trim();
    final hasPhone = detail.customerPhone.isNotEmpty;

    return AppSurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (detail.deviceType.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          detail.deviceType.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    Text(
                      deviceTitle.isNotEmpty ? deviceTitle : 'Unknown Device',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(status: detail.statusDisplay),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.person_rounded,
                  size: 20,
                  color: AppColors.ink500,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        detail.customerName.isNotEmpty
                            ? detail.customerName
                            : 'Walk-in Customer',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (hasPhone)
                        Text(
                          detail.customerPhone,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.ink500,
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasPhone) ...[
                  IconButton.filledTonal(
                    onPressed: () => _makeCall(detail.customerPhone),
                    icon: const Icon(Icons.phone_outlined, size: 18),
                    tooltip: 'Call Customer',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.blue.shade50,
                      foregroundColor: Colors.blue.shade700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: () => _openWhatsApp(detail.customerPhone),
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    tooltip: 'WhatsApp Customer',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.green.shade50,
                      foregroundColor: Colors.green.shade700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildChipBadge(
                icon: Icons.shield_outlined,
                label: detail.isUnderWarranty ? 'Under Warranty' : 'Out of Warranty',
                bgColor: detail.isUnderWarranty ? const Color(0xFFE2F8ED) : const Color(0xFFF1F5F9),
                fgColor: detail.isUnderWarranty ? const Color(0xFF0E8E54) : AppColors.ink500,
              ),
              if (detail.deviceSerial.isNotEmpty)
                InkWell(
                  onTap: () => _copyToClipboard(detail.deviceSerial, 'Serial Number'),
                  borderRadius: BorderRadius.circular(6),
                  child: _buildChipBadge(
                    icon: Icons.fingerprint_rounded,
                    label: 'S/N: ${detail.deviceSerial}',
                    bgColor: const Color(0xFFF1F5F9),
                    fgColor: AppColors.ink700,
                  ),
                ),
              if (detail.assignedTo.isNotEmpty)
                _buildChipBadge(
                  icon: Icons.engineering_outlined,
                  label: 'Tech: ${detail.assignedTo}',
                  bgColor: const Color(0xFFF1F5F9),
                  fgColor: AppColors.ink700,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceStorageCard(JobDetail detail) {
    final hasPassword = detail.devicePassword.isNotEmpty;
    final hasRack = detail.rackLocation.isNotEmpty || detail.rackShort.isNotEmpty;
    final rackText = detail.rackLocation.isNotEmpty
        ? detail.rackLocation
        : (detail.rackShort.isNotEmpty ? detail.rackShort : 'Not assigned');
    final isJobFinished = const {'Completed', 'Ready for Pickup', 'Closed'}.contains(detail.status);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isJobFinished
              ? const Color(0xFF10B981).withValues(alpha: 0.4)
              : AppColors.primary.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: (isJobFinished ? const Color(0xFF10B981) : AppColors.primary).withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isJobFinished ? const Color(0xFFDCFCE7) : AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isJobFinished ? Icons.inventory_2_outlined : Icons.devices_other_rounded,
                      size: 18,
                      color: isJobFinished ? const Color(0xFF15803D) : AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isJobFinished ? 'FINISHED DEVICE & RACK LOCATION' : 'DEVICE & RACK LOCATION',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: isJobFinished ? const Color(0xFF15803D) : AppColors.primary,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: _isBusy ? null : () => _openChangeRackSheet(detail),
                icon: const Icon(Icons.edit_location_alt_outlined, size: 15),
                label: const Text('Change Rack', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Passcode / Pattern column
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: hasPassword
                        ? const Color(0xFFFEF3C7).withValues(alpha: 0.4)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: hasPassword
                          ? const Color(0xFFF59E0B).withValues(alpha: 0.3)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.key_rounded, size: 14, color: AppColors.ink500),
                          SizedBox(width: 4),
                          Text(
                            'PASSCODE / PIN',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              hasPassword ? detail.devicePassword : 'No PIN / Open',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: hasPassword
                                    ? const Color(0xFFB45309)
                                    : AppColors.ink500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (hasPassword)
                            InkWell(
                              onTap: () => _copyToClipboard(
                                detail.devicePassword,
                                'Device Passcode',
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.copy_rounded,
                                  size: 16,
                                  color: Color(0xFFB45309),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Storage Rack column (tappable to edit)
              Expanded(
                child: InkWell(
                  onTap: _isBusy ? null : () => _openChangeRackSheet(detail),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: hasRack
                          ? (isJobFinished
                              ? const Color(0xFFFEF3C7).withValues(alpha: 0.5)
                              : const Color(0xFFE0F2FE).withValues(alpha: 0.5))
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: hasRack
                            ? (isJobFinished
                                ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                                : const Color(0xFF38BDF8).withValues(alpha: 0.3))
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.shelves,
                              size: 14,
                              color: isJobFinished ? const Color(0xFFD97706) : AppColors.ink500,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isJobFinished ? 'STORAGE RACK' : 'STORAGE SHELF',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: isJobFinished ? const Color(0xFF92400E) : AppColors.ink500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          rackText,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: hasRack
                                ? (isJobFinished ? const Color(0xFF78350F) : const Color(0xFF0369A1))
                                : AppColors.ink500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (isJobFinished) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFBBF7D0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF16A34A)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hasRack
                          ? 'Device shelved in $rackText. Ready for front desk pickup.'
                          : 'Repair complete. Tap "Change Rack" above to assign storage slot.',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF15803D), fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReportedIssueCard(JobDetail detail) {
    final hasIssue = detail.reportedIssue.isNotEmpty;
    final hasAccessories = detail.additionalItems.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: Color(0xFFB45309),
              ),
              SizedBox(width: 8),
              Text(
                'REPORTED ISSUE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFB45309),
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hasIssue ? detail.reportedIssue : 'No specific fault described.',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF78350F),
              height: 1.35,
            ),
          ),
          if (hasAccessories) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.inventory_2_outlined,
                    size: 14,
                    color: Color(0xFFB45309),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Accessories: ${detail.additionalItems}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF92400E),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChecklistCard(JobDetail detail) {
    final isFinished = const {'Completed', 'Ready for Pickup', 'Closed'}.contains(detail.status);
    if (isFinished) {
      return _buildCompletedChecklistCard(detail);
    }

    final schema = detail.checklistSchema;
    final totalCount = schema.length;
    var completedCount = 0;

    for (final item in schema) {
      final val = _checklistAnswers[item.key];
      if (item.type == 'checkbox') {
        if (val == true || val == 'true' || val == 1) {
          completedCount++;
        }
      } else if (val != null && val.toString().trim().isNotEmpty) {
        completedCount++;
      }
    }

    final title = detail.checklistTitle.isNotEmpty
        ? detail.checklistTitle
        : 'Pre-Repair Inspection Checklist';

    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$completedCount of $totalCount tests checked',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.ink500,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _isChecklistSaving ? null : _saveChecklist,
                icon: _isChecklistSaving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline, size: 16),
                label: Text(_isChecklistSaving ? 'Saving' : 'Save'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: totalCount > 0 ? (completedCount / totalCount) : 0,
              backgroundColor: const Color(0xFFE2E8F0),
              color: completedCount == totalCount
                  ? const Color(0xFF10B981)
                  : AppColors.primary,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          ...schema.map((item) {
            final isChecked = _checklistAnswers[item.key] == true ||
                _checklistAnswers[item.key] == 'true' ||
                _checklistAnswers[item.key] == 1;

            if (item.type == 'checkbox') {
              return CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (item.required)
                      const Text(
                        ' *',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                subtitle: item.helpText.isNotEmpty
                    ? Text(
                        item.helpText,
                        style: const TextStyle(fontSize: 11, color: AppColors.ink500),
                      )
                    : null,
                value: isChecked,
                activeColor: AppColors.primary,
                onChanged: (val) {
                  setState(() {
                    _checklistAnswers[item.key] = val == true;
                  });
                },
              );
            }

            // Dropdown selection field
            if (item.type == 'select') {
              final currentVal = (_checklistAnswers[item.key] ?? '').toString().trim();
              final validValue = item.options.contains(currentVal) ? currentVal : null;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: DropdownButtonFormField<String>(
                  initialValue: validValue,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: item.required ? '${item.label} *' : item.label,
                    helperText: item.helpText.isNotEmpty ? item.helpText : null,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  items: [
                    if (!item.required)
                      const DropdownMenuItem(
                        value: '',
                        child: Text('-- Select --', style: TextStyle(color: AppColors.ink500)),
                      ),
                    ...item.options.map(
                      (opt) => DropdownMenuItem(
                        value: opt,
                        child: Text(opt, style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                  ],
                  onChanged: (val) {
                    setState(() {
                      _checklistAnswers[item.key] = val ?? '';
                    });
                  },
                ),
              );
            }

            // Numeric field
            if (item.type == 'number') {
              final currentVal = (_checklistAnswers[item.key] ?? '').toString();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: TextFormField(
                  key: ValueKey('num_${item.key}'),
                  initialValue: currentVal,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: item.required ? '${item.label} *' : item.label,
                    hintText: item.placeholder.isNotEmpty ? item.placeholder : null,
                    helperText: item.helpText.isNotEmpty ? item.helpText : null,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onChanged: (val) {
                    _checklistAnswers[item.key] = val.trim();
                  },
                ),
              );
            }

            // Text / Textarea field
            final currentVal = (_checklistAnswers[item.key] ?? '').toString();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: TextFormField(
                key: ValueKey('txt_${item.key}'),
                initialValue: currentVal,
                maxLines: item.type == 'textarea' ? 3 : 1,
                decoration: InputDecoration(
                  labelText: item.required ? '${item.label} *' : item.label,
                  hintText: item.placeholder.isNotEmpty ? item.placeholder : null,
                  helperText: item.helpText.isNotEmpty ? item.helpText : null,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (val) {
                  _checklistAnswers[item.key] = val.trim();
                },
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCompletedChecklistCard(JobDetail detail) {
    final schema = detail.checklistSchema;
    final totalCount = schema.length;
    var passedCount = 0;

    for (final item in schema) {
      final val = _checklistAnswers[item.key];
      if (item.type == 'checkbox') {
        if (val == true || val == 'true' || val == 1) {
          passedCount++;
        }
      } else if (val != null && val.toString().trim().isNotEmpty) {
        passedCount++;
      }
    }

    final title = detail.checklistTitle.isNotEmpty
        ? detail.checklistTitle
        : 'Quality Inspection & Testing Report';

    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(0xFFDCFCE7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.verified_rounded,
                  color: Color(0xFF16A34A),
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    Text(
                      '$passedCount of $totalCount QA items verified & recorded',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.ink500,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'QA Passed',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF16A34A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
          ...schema.map((item) {
            final rawVal = _checklistAnswers[item.key];
            final isChecked = rawVal == true || rawVal == 'true' || rawVal == 1;

            if (item.type == 'checkbox') {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      isChecked ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                      size: 18,
                      color: isChecked ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isChecked ? FontWeight.w600 : FontWeight.w400,
                          color: isChecked ? AppColors.ink900 : AppColors.ink500,
                        ),
                      ),
                    ),
                    Text(
                      isChecked ? 'Verified' : 'Not Tested',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isChecked ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              );
            }

            final displayVal = (rawVal ?? '').toString().trim();
            final hasVal = displayVal.isNotEmpty;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Icon(
                    hasVal ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                    size: 18,
                    color: hasVal ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink900,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: hasVal ? const Color(0xFFF1F5F9) : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      hasVal ? displayVal : '—',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: hasVal ? AppColors.ink900 : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCompletedHeroBanner(JobDetail detail) {
    final isReady = detail.status == 'Ready for Pickup';
    final isClosed = detail.status == 'Closed';

    final Color bgColor = isClosed
        ? const Color(0xFFF8FAFC)
        : isReady
            ? const Color(0xFFF0FDF4)
            : const Color(0xFFF0FDF4);

    final Color borderColor = isClosed
        ? const Color(0xFFE2E8F0)
        : isReady
            ? const Color(0xFF86EFAC)
            : const Color(0xFF86EFAC);

    final Color iconColor = isClosed
        ? const Color(0xFF64748B)
        : const Color(0xFF16A34A);

    final String title = isClosed
        ? 'Job Closed & Handed Over'
        : isReady
            ? 'Device Ready for Customer Pickup'
            : 'Repair Completed Successfully';

    final String description = isClosed
        ? 'Device has been collected by customer and settlement finalized.'
        : isReady
            ? 'Repair QA passed. Customer notified for collection & settlement.'
            : 'Service and testing verified. Device prepared for reception pickup.';

    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isClosed ? const Color(0x1F64748B) : const Color(0x1F16A34A),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isClosed
                        ? Icons.task_alt_rounded
                        : isReady
                            ? Icons.check_circle_outline_rounded
                            : Icons.verified_rounded,
                    color: iconColor,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: isClosed ? const Color(0xFF334155) : const Color(0xFF14532D),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 12,
                          color: isClosed ? const Color(0xFF64748B) : const Color(0xFF166534),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (detail.assignedTo.isNotEmpty)
                  Text(
                    'Technician: ${detail.assignedTo}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.ink900),
                  ),
                Text(
                  'Updated: ${detail.updatedAt}',
                  style: const TextStyle(fontSize: 11, color: AppColors.ink500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTasksCard(JobDetail detail) {
    final tasks = detail.tasks;
    final legacyTask = detail.taskAssignment;

    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    'Directives & Tasks',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (tasks.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${tasks.length}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (tasks.isEmpty && legacyTask == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No active directives for this job. Directives dispatched by management will appear here.',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            )
          else ...[
            ...tasks.map((task) => _buildTaskItemTile(task)),
            if (tasks.isEmpty && legacyTask != null)
              _buildLegacyTaskTile(legacyTask),
          ],
        ],
      ),
    );
  }

  Widget _buildTaskItemTile(LinkedTaskItem task) {
    final isDone = task.status == 'done';
    final isInProgress = task.status == 'in_progress';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDone
            ? const Color(0xFFF8FAFC)
            : (isInProgress
                ? const Color(0xFFEFF6FF)
                : const Color(0xFFFAFAFA)),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDone
              ? const Color(0xFFE2E8F0)
              : (isInProgress
                  ? const Color(0xFFBFDBFE)
                  : const Color(0xFFE2E8F0)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    decoration: isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              PriorityBadge(
                priority: task.priority,
                label: task.priorityDisplay,
              ),
            ],
          ),
          if (task.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              task.description,
              style: const TextStyle(fontSize: 12, color: AppColors.ink700),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                task.assignedTo.isNotEmpty
                    ? '👤 ${task.assignedTo}'
                    : '👤 Unassigned',
                style: const TextStyle(fontSize: 11, color: AppColors.ink500),
              ),
              StatusPill(status: task.statusDisplay),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegacyTaskTile(TaskAssignmentDetail task) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.instructions.isNotEmpty
                      ? task.instructions
                      : 'Assigned Directive',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              PriorityBadge(
                priority: task.priority,
                label: task.priorityDisplay,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                task.assignedBy.isNotEmpty ? 'By ${task.assignedBy}' : '',
                style: const TextStyle(fontSize: 11, color: AppColors.ink500),
              ),
              StatusPill(status: task.statusDisplay),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildServiceLinesCard(JobDetail detail) {
    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parts & Service Lines',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    'Total: Rs ${detail.grandTotal}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
              if (detail.canManageServiceLogs)
                FilledButton.tonalIcon(
                  onPressed: _isServiceBusy ? null : () => _openServiceLineEditor(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Line'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (detail.serviceLogs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No parts or service charges recorded yet.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            )
          else
            ...detail.serviceLogs.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE5EAF1)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              line.description,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (line.isProductSale)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0F2FE),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'Inventory Part',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0369A1),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            'Part: Rs ${line.partCost}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Labor: Rs ${line.serviceCharge}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      if (line.isProductSale) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Qty: ${line.productQuantity} | Unit: Rs ${line.productUnitPrice} | Line: Rs ${line.productLineTotal}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.ink500,
                          ),
                        ),
                      ],
                      if (detail.canManageServiceLogs && !line.isProductSale) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: _isServiceBusy
                                  ? null
                                  : () => _openServiceLineEditor(line: line),
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              label: const Text('Edit'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            const SizedBox(width: 4),
                            TextButton.icon(
                              onPressed: _isServiceBusy
                                  ? null
                                  : () => _deleteServiceLine(line),
                              icon: const Icon(Icons.delete_outline, size: 16),
                              label: const Text('Delete'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                foregroundColor: Colors.red.shade700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFinancialSummaryCard(JobDetail detail) {
    if (_isTechnician) {
      return const SizedBox.shrink();
    }
    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Financial Breakdown',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          _FinanceRow(label: 'Parts Total', value: detail.partTotal),
          _FinanceRow(label: 'Labor & Service Total', value: detail.serviceTotal),
          _FinanceRow(label: 'Subtotal', value: detail.subtotal),
          _FinanceRow(label: 'Discount', value: detail.discountAmount),
          const Divider(height: 14),
          _FinanceRow(
            label: 'Grand Total',
            value: detail.grandTotal,
            isBold: true,
          ),
        ],
      ),
    );
  }

  Widget _buildTechnicianNotesCard(JobDetail detail) {
    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Technician Notes',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              if (detail.canEditNotes && !_isEditingNotes)
                TextButton.icon(
                  onPressed: _isNotesSaving
                      ? null
                      : () {
                          setState(() {
                            _isEditingNotes = true;
                          });
                        },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_isEditingNotes || detail.technicianNotes.isNotEmpty) ...[
            TextField(
              controller: _notesController,
              readOnly: !(_isEditingNotes && detail.canEditNotes),
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Add internal repair notes or updates...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ] else
            Text(
              'No technician notes added yet.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          if (detail.canEditNotes && _isEditingNotes) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isNotesSaving
                      ? null
                      : () {
                          setState(() {
                            _isEditingNotes = false;
                            _notesController.text = detail.technicianNotes;
                          });
                        },
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isNotesSaving ? null : () => _saveNotes(detail),
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(_isNotesSaving ? 'Saving...' : 'Save Notes'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeedbackCard(JobDetail detail) {
    return AppSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Customer Feedback',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          if (detail.feedbackRating > 0)
            Row(
              children: List.generate(5, (idx) {
                return Icon(
                  idx < detail.feedbackRating
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: Colors.amber.shade700,
                  size: 20,
                );
              }),
            ),
          if (detail.feedbackComment.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail.feedbackComment,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
          if (detail.feedbackDate.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Received: ${detail.feedbackDate}',
              style: const TextStyle(fontSize: 11, color: AppColors.ink500),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStickyActionBar(JobDetail detail) {
    final actions = detail.availableActions;
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    final firstAction = actions.first;
    final otherActions = actions.length > 1 ? actions.sublist(1) : <JobActionOption>[];

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        MediaQuery.of(context).padding.bottom + 10,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            offset: const Offset(0, -3),
            blurRadius: 10,
          ),
        ],
        border: Border(
          top: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _isBusy ? null : () => _runAction(firstAction, detail: detail),
              icon: _isActionBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.bolt_rounded, size: 20),
              label: Text(
                firstAction.label,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (otherActions.isNotEmpty) ...[
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _isBusy ? null : () => _showAllActionsSheet(detail),
              icon: const Icon(Icons.more_horiz_rounded),
              label: const Text('Actions'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChipBadge({
    required IconData icon,
    required String label,
    required Color bgColor,
    required Color fgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fgColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: fgColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HELPER COMPONENTS
// ---------------------------------------------------------------------------

class _FinanceRow extends StatelessWidget {
  const _FinanceRow({
    required this.label,
    required this.value,
    this.isBold = false,
  });

  final String label;
  final String value;
  final bool isBold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
      fontSize: isBold ? 15 : 13,
      color: isBold ? AppColors.ink900 : AppColors.ink700,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text('Rs $value', style: style),
        ],
      ),
    );
  }
}

class _ServiceLineInput {
  const _ServiceLineInput({
    required this.description,
    required this.partCost,
    required this.serviceCharge,
    required this.salesInvoiceNumber,
  });

  final String description;
  final String partCost;
  final String serviceCharge;
  final String salesInvoiceNumber;
}

class _ServiceLineEditorSheet extends StatefulWidget {
  const _ServiceLineEditorSheet({this.initialLine});

  final JobServiceLine? initialLine;

  @override
  State<_ServiceLineEditorSheet> createState() => _ServiceLineEditorSheetState();
}

class _ServiceLineEditorSheetState extends State<_ServiceLineEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _descriptionController;
  late final TextEditingController _partCostController;
  late final TextEditingController _serviceChargeController;
  late final TextEditingController _invoiceController;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialLine;
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _partCostController = TextEditingController(text: initial?.partCost ?? '0');
    _serviceChargeController = TextEditingController(
      text: initial?.serviceCharge ?? '0',
    );
    _invoiceController = TextEditingController(
      text: initial?.salesInvoiceNumber ?? '',
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _partCostController.dispose();
    _serviceChargeController.dispose();
    _invoiceController.dispose();
    super.dispose();
  }

  String? _validateAmount(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) {
      return null;
    }
    if (num.tryParse(text) == null) {
      return 'Enter a valid amount';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(
      _ServiceLineInput(
        description: _descriptionController.text.trim(),
        partCost: _partCostController.text.trim().isEmpty
            ? '0'
            : _partCostController.text.trim(),
        serviceCharge: _serviceChargeController.text.trim().isEmpty
            ? '0'
            : _serviceChargeController.text.trim(),
        salesInvoiceNumber: _invoiceController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 16),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.initialLine == null
                    ? 'Add Part or Labor Line'
                    : 'Edit Service Line',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Part / Labor Description',
                  hintText: 'e.g. OEM Battery Replacement',
                ),
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'Description is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _partCostController,
                      decoration: const InputDecoration(labelText: 'Part Cost (Rs)'),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: _validateAmount,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _serviceChargeController,
                      decoration: const InputDecoration(labelText: 'Labor Fee (Rs)'),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: _validateAmount,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _invoiceController,
                decoration: const InputDecoration(
                  labelText: 'Sales Invoice Number (Optional)',
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    widget.initialLine == null ? 'Add Line' : 'Save Changes',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeRackSheet extends StatefulWidget {
  const _ChangeRackSheet({
    required this.jobCode,
    required this.currentRackId,
    required this.currentColumn,
    required this.availableRacks,
    required this.jobsService,
  });

  final String jobCode;
  final int? currentRackId;
  final int? currentColumn;
  final List<DeviceRackOption> availableRacks;
  final JobsService jobsService;

  @override
  State<_ChangeRackSheet> createState() => _ChangeRackSheetState();
}

class _ChangeRackSheetState extends State<_ChangeRackSheet> {
  int? _selectedRackId;
  int? _selectedColumn;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedRackId = widget.currentRackId;
    _selectedColumn = widget.currentColumn;
  }

  DeviceRackOption? get _currentRack {
    if (_selectedRackId == null) return null;
    try {
      return widget.availableRacks.firstWhere((r) => r.id == _selectedRackId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
    });

    try {
      final msg = await widget.jobsService.updateJobRack(
        jobCode: widget.jobCode,
        rackId: _selectedRackId,
        rackColumn: _selectedColumn,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF10B981),
            content: Text(msg),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.warningFg,
            content: Text(e.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final rack = _currentRack;
    final totalCols = rack?.totalColumns ?? 0;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Change Storage Rack',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.availableRacks.isEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'No storage racks configured for this shop workspace.',
                style: TextStyle(fontSize: 13, color: Color(0xFF92400E)),
              ),
            ),
          ] else ...[
            DropdownButtonFormField<int?>(
              initialValue: widget.availableRacks.any((r) => r.id == _selectedRackId)
                  ? _selectedRackId
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Storage Rack / Shelf',
                prefixIcon: const Icon(Icons.shelves),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('No Rack / Unassigned', style: TextStyle(color: AppColors.ink500)),
                ),
                ...widget.availableRacks.map(
                  (r) => DropdownMenuItem<int?>(
                    value: r.id,
                    child: Text(
                      '${r.displayName} (${r.freeCount} free / ${r.totalColumns})',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
              onChanged: (val) {
                setState(() {
                  _selectedRackId = val;
                  if (val == null) {
                    _selectedColumn = null;
                  } else {
                    final newRack = widget.availableRacks.firstWhere(
                      (r) => r.id == val,
                      orElse: () => widget.availableRacks.first,
                    );
                    if (_selectedColumn != null && _selectedColumn! > newRack.totalColumns) {
                      _selectedColumn = null;
                    }
                  }
                });
              },
            ),
            if (_selectedRackId != null && rack != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFBBF7D0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF15803D)),
                        const SizedBox(width: 4),
                        Text(
                          '${rack.freeCount} Free',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF15803D)),
                        ),
                      ],
                    ),
                  ),
                  if (rack.occupiedCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.inventory_2_outlined, size: 14, color: Color(0xFFDC2626)),
                          const SizedBox(width: 4),
                          Text(
                            '${rack.occupiedCount} Occupied',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFDC2626)),
                          ),
                        ],
                      ),
                    ),
                  if (rack.freeColumns.isNotEmpty)
                    Text(
                      '(Available: Col ${rack.freeColumns.take(6).join(', ')}${rack.freeColumns.length > 6 ? '...' : ''})',
                      style: const TextStyle(fontSize: 11, color: AppColors.ink500),
                    ),
                ],
              ),
            ],
            if (_selectedRackId != null && totalCols > 0) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: (_selectedColumn != null && _selectedColumn! <= totalCols)
                    ? _selectedColumn
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Column / Slot Number',
                  prefixIcon: const Icon(Icons.view_column_outlined),
                  helperText: 'Select slot inside ${rack?.name}',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('General Rack (No specific slot)', style: TextStyle(color: AppColors.ink500)),
                  ),
                  for (int i = 1; i <= totalCols; i++) ...[
                    () {
                      final isOcc = rack?.isColumnOccupied(i) ?? false;
                      final occList = rack?.getOccupantsForColumn(i) ?? const [];
                      final occJobCodes = occList
                          .map((o) => (o is Map && o['job_code'] != null) ? o['job_code'].toString() : '')
                          .where((s) => s.isNotEmpty)
                          .join(', ');

                      return DropdownMenuItem<int?>(
                        value: i,
                        child: Row(
                          children: [
                            Text(
                              'Column $i',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isOcc ? const Color(0xFFDC2626) : const Color(0xFF16A34A),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isOcc ? const Color(0xFFFEE2E2) : const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isOcc
                                    ? (occJobCodes.isNotEmpty ? 'Occupied [$occJobCodes]' : 'Occupied')
                                    : 'Available',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: isOcc ? const Color(0xFFDC2626) : const Color(0xFF15803D),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }(),
                  ],
                ],
                onChanged: (val) {
                  setState(() {
                    _selectedColumn = val;
                  });
                },
              ),
              if (_selectedColumn != null && rack != null) ...[
                if (rack.isColumnOccupied(_selectedColumn!)) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFDC2626)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Col $_selectedColumn is currently occupied by: ${rack.getOccupantsForColumn(_selectedColumn!).map((o) => (o is Map && o['job_code'] != null) ? '${o['job_code']}${o['device_type'] != null && o['device_type'].toString().isNotEmpty ? ' (${o['device_type']})' : ''}' : '').where((s) => s.isNotEmpty).join(', ')} (can share slot if needed).',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFB91C1C)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFBBF7D0)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_outline, size: 18, color: Color(0xFF16A34A)),
                        const SizedBox(width: 8),
                        Text(
                          'Col $_selectedColumn is currently vacant.',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF15803D)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_isSaving ? 'Updating...' : 'Save Rack Location'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}


