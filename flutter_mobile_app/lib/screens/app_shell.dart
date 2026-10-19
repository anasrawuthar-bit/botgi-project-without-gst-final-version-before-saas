import 'dart:async';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/jobs_service.dart';
import '../services/management_service.dart';
import '../services/notification_service.dart';
import '../services/tasks_service.dart';
import 'dashboard_screen.dart';
import 'feedback_screen.dart';
import 'job_detail_screen.dart';
import 'jobs_screen.dart';
import 'profile_screen.dart';
import 'task_detail_screen.dart';
import 'tasks_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.authService,
    required this.jobsService,
    required this.managementService,
    required this.tasksService,
    required this.onLogout,
  });

  final AuthService authService;
  final JobsService jobsService;
  final ManagementService managementService;
  final TasksService tasksService;
  final Future<void> Function() onLogout;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  Timer? _pollTimer;
  final Set<int> _knownTaskIds = <int>{};
  final Set<String> _knownJobCodes = <String>{};
  int _activeTaskCount = 0;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _checkNewTasks(initial: true);
    _checkNewJobs(initial: true);
    _pollTimer = Timer.periodic(
      const Duration(seconds: 18),
      (_) {
        _checkNewTasks();
        _checkNewJobs();
      },
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _initNotifications() {
    NotificationService.instance.init();
    NotificationService.instance.onNotificationTap = (taskId) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TaskDetailScreen(
            taskId: taskId,
            tasksService: widget.tasksService,
            jobsService: widget.jobsService,
          ),
        ),
      );
    };
    NotificationService.instance.onJobNotificationTap = (jobCode) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => JobDetailScreen(
            jobCode: jobCode,
            jobsService: widget.jobsService,
            tasksService: widget.tasksService,
          ),
        ),
      );
    };
  }

  Future<void> _checkNewJobs({bool initial = false}) async {
    try {
      final jobs = await widget.jobsService.fetchJobs(scope: 'active');
      if (!mounted) return;

      if (initial) {
        _knownJobCodes.clear();
        for (final j in jobs) {
          _knownJobCodes.add(j.jobCode);
        }
      } else {
        final newJobs = jobs.where((j) => !_knownJobCodes.contains(j.jobCode)).toList();
        for (final job in newJobs) {
          _knownJobCodes.add(job.jobCode);
          // 1. Android native push notification
          NotificationService.instance.showJobNotification(
            jobCode: job.jobCode,
            customerName: job.customerName,
            device: job.device,
          );

          // 2. In-app interactive SnackBar
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.build_circle_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'New Job Assigned: ${job.jobCode} (${job.device})',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFF0F172A),
                duration: const Duration(seconds: 6),
                action: SnackBarAction(
                  label: 'VIEW',
                  textColor: const Color(0xFF38BDF8),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => JobDetailScreen(
                          jobCode: job.jobCode,
                          jobsService: widget.jobsService,
                          tasksService: widget.tasksService,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          }
        }
      }
    } catch (_) {
      // Ignore background poll errors silently
    }
  }

  Future<void> _checkNewTasks({bool initial = false}) async {
    try {
      final tasks = await widget.tasksService.fetchTasks(
        mineOnly: true,
        status: 'active',
      );

      if (!mounted) return;

      if (initial) {
        _knownTaskIds.clear();
        for (final t in tasks) {
          _knownTaskIds.add(t.id);
        }
        setState(() {
          _activeTaskCount = tasks.length;
        });
      } else {
        final newTasks = tasks.where((t) => !_knownTaskIds.contains(t.id)).toList();
        for (final task in newTasks) {
          _knownTaskIds.add(task.id);
          // 1. Android native push notification
          NotificationService.instance.showTaskNotification(
            taskId: task.id,
            title: task.title,
            priority: task.priorityDisplay,
            description: task.description,
          );

          // 2. In-app interactive SnackBar
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.assignment_turned_in, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'New Task: ${task.title}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFF0F172A),
                duration: const Duration(seconds: 6),
                action: SnackBarAction(
                  label: 'OPEN',
                  textColor: const Color(0xFF38BDF8),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TaskDetailScreen(
                          taskId: task.id,
                          tasksService: widget.tasksService,
                          jobsService: widget.jobsService,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          }
        }
        if (mounted) {
          setState(() {
            _activeTaskCount = tasks.length;
          });
        }
      }
    } catch (_) {
      // Ignore background poll errors silently
    }
  }

  String _jobsInitialScope = 'active';
  String _jobsInitialPreset = 'all';

  void _navigateToJobs({String? scope, String? preset}) {
    setState(() {
      _jobsInitialScope = scope ?? 'all';
      _jobsInitialPreset = preset ?? 'all';
      _currentIndex = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardScreen(
        authService: widget.authService,
        jobsService: widget.jobsService,
        managementService: widget.managementService,
        tasksService: widget.tasksService,
        onNavigateToTasks: () {
          setState(() {
            _currentIndex = 2;
          });
        },
        onNavigateToJobs: _navigateToJobs,
      ),
      JobsScreen(
        authService: widget.authService,
        jobsService: widget.jobsService,
        initialScope: _jobsInitialScope,
        initialPreset: _jobsInitialPreset,
      ),
      TasksScreen(
        tasksService: widget.tasksService,
        jobsService: widget.jobsService,
      ),
      FeedbackScreen(managementService: widget.managementService),
      ProfileScreen(authService: widget.authService, onLogout: widget.onLogout),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Dashboard',
          ),
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Jobs',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _activeTaskCount > 0,
              label: Text('$_activeTaskCount'),
              child: const Icon(Icons.task_alt_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _activeTaskCount > 0,
              label: Text('$_activeTaskCount'),
              child: const Icon(Icons.task_alt_rounded),
            ),
            label: 'Tasks',
          ),
          const NavigationDestination(
            icon: Icon(Icons.star_outline_rounded),
            selectedIcon: Icon(Icons.star_rounded),
            label: 'Feedback',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
