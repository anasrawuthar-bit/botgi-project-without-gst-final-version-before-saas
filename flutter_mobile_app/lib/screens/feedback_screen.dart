import 'package:flutter/material.dart';

import '../models/feedback_model.dart';
import '../services/management_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_surface_card.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({
    super.key,
    required this.managementService,
  });

  final ManagementService managementService;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  TechnicianFeedbackResponse? _feedbackData;
  bool _isLoading = true;
  String? _errorMessage;
  String _selectedRatingFilter = 'all';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadFeedback();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFeedback({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final res = await widget.managementService.fetchTechnicianFeedback(
        rating: _selectedRatingFilter,
        query: _searchController.text,
      );
      if (mounted) {
        setState(() {
          _feedbackData = res;
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString().replaceAll('Exception:', '').trim();
        });
      }
    }
  }

  Color _getRatingColor(int rating) {
    if (rating >= 8) return const Color(0xFF16A34A); // Green
    if (rating >= 6) return const Color(0xFFD97706); // Amber
    return const Color(0xFFDC2626); // Red
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Feedback', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => _loadFeedback(silent: false),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _loadFeedback(silent: true),
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading && _feedbackData == null) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null && _feedbackData == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48, color: Color(0xFFDC2626)),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: AppColors.ink700),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _loadFeedback(silent: false),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final data = _feedbackData;
    final metrics = data?.metrics ?? const TechnicianFeedbackMetrics();
    final breakdown = data?.ratingBreakdown ?? const RatingBreakdown();
    final reviews = data?.reviews ?? <CustomerReviewItem>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // Overall Score Overview Card
        AppSurfaceCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.star_rounded, color: Color(0xFFD97706), size: 22),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Quality & Feedback',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Text(
                            'Lifetime customer ratings',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (metrics.totalReviews > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF86EFAC)),
                      ),
                      child: Text(
                        metrics.qualityGrade,
                        style: const TextStyle(
                          color: Color(0xFF166534),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              Row(
                children: [
                  // Big rating display
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          metrics.avgRating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFFD97706),
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text('out of 10', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(5, (index) {
                            final filled = index < (metrics.starsRating.round());
                            return Icon(
                              filled ? Icons.star_rounded : Icons.star_outline_rounded,
                              size: 16,
                              color: const Color(0xFFD97706),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                  Container(height: 50, width: 1, color: Colors.grey.shade200),
                  // Metrics column
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Satisfaction Rate', style: TextStyle(fontSize: 12.5)),
                              Text(
                                '${metrics.satisfactionRatePct}%',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF16A34A),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total Reviews', style: TextStyle(fontSize: 12.5)),
                              Text(
                                '${metrics.totalReviews}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Quality Index', style: TextStyle(fontSize: 12.5)),
                              Text(
                                '${metrics.qualityScorePct.toStringAsFixed(1)}%',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Search Bar
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _loadFeedback(),
          decoration: InputDecoration(
            hintText: 'Search customer, ticket, or comments...',
            hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      _loadFeedback();
                    },
                  )
                : null,
            filled: true,
            fillColor: Colors.grey.shade50,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Filter Chips Horizontal Scroll
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildFilterChip('All (${metrics.totalReviews})', 'all'),
              const SizedBox(width: 8),
              _buildFilterChip('★ 10/10 (${breakdown.count10})', '10'),
              const SizedBox(width: 8),
              _buildFilterChip('★ 8–9 (${breakdown.countHigh})', 'high'),
              const SizedBox(width: 8),
              _buildFilterChip('★ 6–7 (${breakdown.countMid})', 'mid'),
              const SizedBox(width: 8),
              _buildFilterChip('★ <6 (${breakdown.countLow})', 'low'),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Reviews Feed Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Customer Reviews',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              '${reviews.length} shown',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),

        const SizedBox(height: 10),

        // Reviews List
        if (reviews.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.star_outline_rounded, size: 48, color: Colors.grey.shade400),
                  const SizedBox(height: 10),
                  const Text(
                    'No reviews found',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _selectedRatingFilter != 'all' || _searchController.text.isNotEmpty
                        ? 'Try clearing the search or rating filter.'
                        : 'Customer feedback submitted on completed tickets will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          )
        else
          ...reviews.map((review) => _buildReviewCard(review)),
      ],
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _selectedRatingFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
        color: isSelected ? Colors.white : AppColors.ink700,
      ),
      selectedColor: AppColors.primary,
      backgroundColor: Colors.white,
      side: BorderSide(
        color: isSelected ? AppColors.primary : Colors.grey.shade300,
      ),
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _selectedRatingFilter = value;
          });
          _loadFeedback();
        }
      },
    );
  }

  Widget _buildReviewCard(CustomerReviewItem review) {
    final color = _getRatingColor(review.feedbackRating);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppSurfaceCard(
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
                        review.customerName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (review.deviceType.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          review.deviceType,
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_rounded, size: 14, color: color),
                      const SizedBox(width: 3),
                      Text(
                        '${review.feedbackRating}/10',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: color,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (review.feedbackComment.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(color: color, width: 3),
                  ),
                ),
                child: Text(
                  '"${review.feedbackComment}"',
                  style: const TextStyle(
                    fontStyle: FontStyle.italic,
                    fontSize: 12.5,
                    color: AppColors.ink900,
                  ),
                ),
              )
            else
              Text(
                'No written comment provided.',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 12,
                  color: Colors.grey.shade500,
                ),
              ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  review.jobCode,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                Text(
                  review.feedbackDate,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
