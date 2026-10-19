import 'package:flutter/material.dart';

import '../models/job_item.dart';
import '../models/task_model.dart';
import '../services/auth_service.dart';
import '../services/jobs_service.dart';
import '../services/management_service.dart';
import '../services/tasks_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_surface_card.dart';
import '../widgets/status_pill.dart';
import 'client_management_screen.dart';
import 'feedback_screen.dart';
import 'job_detail_screen.dart';
import 'pending_approvals_screen.dart';
import 'product_management_screen.dart';
import 'reports_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.authService,
    required this.jobsService,
    required this.managementService,
    this.tasksService,
    this.onNavigateToTasks,
    this.onNavigateToJobs,
  });

  final AuthService authService;
  final JobsService jobsService;
  final ManagementService managementService;
  final TasksService? tasksService;
  final VoidCallback? onNavigateToTasks;
  final void Function({String? scope, String? preset})? onNavigateToJobs;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with AutomaticKeepAliveClientMixin<DashboardScreen> {
  List<JobItem>? _jobs;
  TaskMetrics _taskMetrics = TaskMetrics();
  int _pendingApprovalsCount = 0;
  bool _isSyncing = false;
  String? _errorMessage;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Synchronous instant cache lookup (0ms perceived latency)
    _jobs = widget.jobsService.getCachedJobs();
    if (widget.tasksService != null) {
      _taskMetrics = widget.tasksService!.cachedMetrics;
    }

    _refresh(silent: _jobs != null);
  }

  Future<void> _loadTaskMetrics() async {
    if (widget.tasksService == null) return;
    try {
      final res = await widget.tasksService!.fetchTasksWithMetrics(status: 'active');
      if (mounted) {
        setState(() {
          _taskMetrics = res.metrics;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadPendingApprovalsCount() async {
    try {
      final res = await widget.managementService.fetchPendingApprovals();
      if (mounted) {
        setState(() {
          _pendingApprovalsCount = res.approvals.length;
        });
      }
    } catch (_) {}
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && _jobs == null) {
      setState(() {
        _isSyncing = true;
        _errorMessage = null;
      });
    } else {
      if (mounted) {
        setState(() {
          _isSyncing = true;
        });
      }
    }

    try {
      final jobs = await widget.jobsService.fetchJobs();
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _isSyncing = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          if (_jobs == null) {
            _errorMessage = e.toString().replaceFirst('Exception: ', '');
          }
        });
      }
    }

    await Future.wait([
      _loadTaskMetrics(),
      _loadPendingApprovalsCount(),
    ]);
  }

  Widget _buildDashboardSkeleton(String username, String role) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Welcome, $username', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text('Role: $role'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          height: 100,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 70,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 70,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final user = widget.authService.currentUser ?? {};
    final username = (user['username'] ?? '').toString();
    final roleRaw = (user['role'] ?? '').toString().toLowerCase();
    final isTechnician = roleRaw == 'technician';
    final role = (user['role'] ?? '').toString().toUpperCase();

    if (_jobs == null && _isSyncing) {
      return SafeArea(child: _buildDashboardSkeleton(username, role));
    }

    if (_jobs == null && _errorMessage != null) {
      return SafeArea(
        child: _ErrorBlock(
          message: _errorMessage!,
          onRetry: () => _refresh(),
        ),
      );
    }

    final jobs = _jobs ?? <JobItem>[];
    final revenue = jobs.fold<double>(
      0,
      (sum, job) => sum + (double.tryParse(job.total) ?? 0),
    );

    return SafeArea(
      child: Column(
        children: [
          if (_isSyncing)
            const LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(silent: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome, $username',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text('Role: $role', style: TextStyle(color: Colors.grey.shade600)),
                      ],
                    ),
                    Container(
                      width: 44,
                      height: 44,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!isTechnician) ...[
                  _RevenueCard(amount: revenue),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 12),
                _DirectivesSummaryCard(
                  metrics: _taskMetrics,
                  onTap: widget.onNavigateToTasks,
                ),
                if (isTechnician) ...[
                  const SizedBox(height: 12),
                  _TechnicianAssignmentCard(
                    pendingCount: _pendingApprovalsCount,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PendingApprovalsScreen(
                            managementService: widget.managementService,
                            title: 'Job Assignments',
                          ),
                        ),
                      );
                      if (mounted) {
                        await _refresh();
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _TechnicianFeedbackCard(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FeedbackScreen(
                            managementService: widget.managementService,
                          ),
                        ),
                      );
                    },
                  ),
                ],
                if (!isTechnician) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Operations',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _ModuleTile(
                          icon: Icons.inventory_2_outlined,
                          title: 'Product Management',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ProductManagementScreen(
                                  managementService: widget.managementService,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ModuleTile(
                          icon: Icons.pending_actions_outlined,
                          title: 'Pending Approvals',
                          badgeCount: _pendingApprovalsCount,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PendingApprovalsScreen(
                                  managementService: widget.managementService,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _ModuleTile(
                          icon: Icons.groups_outlined,
                          title: 'Client Management',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ClientManagementScreen(
                                  managementService: widget.managementService,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ModuleTile(
                          icon: Icons.analytics_outlined,
                          title: 'Reports',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ReportsScreen(
                                  managementService: widget.managementService,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Recent Jobs',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Row(
                      children: [
                        if (widget.onNavigateToJobs != null) ...[
                          TextButton.icon(
                            onPressed: () => widget.onNavigateToJobs!(scope: 'history', preset: 'this_month'),
                            icon: const Icon(Icons.history_rounded, size: 16),
                            label: const Text('History'),
                          ),
                          const SizedBox(width: 4),
                        ],
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
                if (jobs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(child: Text('No jobs found.')),
                  )
                else
                  ...jobs
                      .take(6)
                      .map(
                        (job) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => JobDetailScreen(
                                      jobCode: job.jobCode,
                                      jobsService: widget.jobsService,
                                    ),
                                  ),
                                );
                                if (mounted) {
                                  await _refresh();
                                }
                              },
                              title: Text(job.jobCode),
                              subtitle: Text(
                                '${job.customerName} - ${job.device}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  StatusPill(status: job.status, compact: true),
                                  const SizedBox(height: 4),
                                  Text('Rs ${job.total}'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
}


class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AppSurfaceCard(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, size: 22),
                if (badgeCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$badgeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _TechnicianAssignmentCard extends StatelessWidget {
  const _TechnicianAssignmentCard({
    required this.pendingCount,
    required this.onTap,
  });

  final int pendingCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasPending = pendingCount > 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: hasPending ? const Color(0xFFFFFBEB) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hasPending ? const Color(0xFFFDE68A) : Colors.grey.shade200,
            width: hasPending ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: hasPending ? const Color(0xFFFEF3C7) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                hasPending ? Icons.notification_important_rounded : Icons.assignment_ind_outlined,
                color: hasPending ? const Color(0xFFB45309) : AppColors.ink700,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Job Assignments',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      if (hasPending) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD97706),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$pendingCount New',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasPending
                        ? '$pendingCount new job request(s) awaiting your response'
                        : 'No pending job assignments',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasPending ? const Color(0xFF92400E) : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

class _TechnicianFeedbackCard extends StatelessWidget {
  const _TechnicianFeedbackCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.star_rounded,
                color: Color(0xFFD97706),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quality & Feedback',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'View customer reviews & satisfaction ratings',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

class _RevenueCard extends StatelessWidget {
  const _RevenueCard({required this.amount});

  final double amount;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.accent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Row(
          children: [
            const Icon(Icons.currency_rupee_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Visible Revenue',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Rs ${amount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.warningFg),
            ),
            const SizedBox(height: 10),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _DirectivesSummaryCard extends StatelessWidget {
  const _DirectivesSummaryCard({
    required this.metrics,
    this.onTap,
  });

  final TaskMetrics metrics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: metrics.urgent > 0 ? const Color(0xFFFCA5A5) : Colors.grey.shade200,
            width: metrics.urgent > 0 ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: metrics.urgent > 0 ? const Color(0xFFFEF2F2) : const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                metrics.urgent > 0 ? Icons.bolt_rounded : Icons.assignment_outlined,
                color: metrics.urgent > 0 ? const Color(0xFFDC2626) : const Color(0xFF2563EB),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Directives & Tasks',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      if (metrics.urgent > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${metrics.urgent} Urgent',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${metrics.active} active tasks • ${metrics.inProgress} in progress',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

