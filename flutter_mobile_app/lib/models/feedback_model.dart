class TechnicianFeedbackMetrics {
  const TechnicianFeedbackMetrics({
    this.totalReviews = 0,
    this.avgRating = 0.0,
    this.qualityScorePct = 0.0,
    this.starsRating = 0.0,
    this.qualityGrade = 'No Reviews Yet',
    this.qualityBadgeClass = 'bg-secondary',
    this.satisfactionRatePct = 0,
    this.highRatingsCount = 0,
  });

  final int totalReviews;
  final double avgRating;
  final double qualityScorePct;
  final double starsRating;
  final String qualityGrade;
  final String qualityBadgeClass;
  final int satisfactionRatePct;
  final int highRatingsCount;

  factory TechnicianFeedbackMetrics.fromJson(Map<String, dynamic> json) {
    return TechnicianFeedbackMetrics(
      totalReviews: (json['total_reviews'] is int)
          ? json['total_reviews'] as int
          : int.tryParse('${json['total_reviews']}') ?? 0,
      avgRating: (json['avg_rating'] is num)
          ? (json['avg_rating'] as num).toDouble()
          : double.tryParse('${json['avg_rating']}') ?? 0.0,
      qualityScorePct: (json['quality_score_pct'] is num)
          ? (json['quality_score_pct'] as num).toDouble()
          : double.tryParse('${json['quality_score_pct']}') ?? 0.0,
      starsRating: (json['stars_rating'] is num)
          ? (json['stars_rating'] as num).toDouble()
          : double.tryParse('${json['stars_rating']}') ?? 0.0,
      qualityGrade: (json['quality_grade'] ?? 'No Reviews Yet').toString(),
      qualityBadgeClass: (json['quality_badge_class'] ?? 'bg-secondary').toString(),
      satisfactionRatePct: (json['satisfaction_rate_pct'] is int)
          ? json['satisfaction_rate_pct'] as int
          : int.tryParse('${json['satisfaction_rate_pct']}') ?? 0,
      highRatingsCount: (json['high_ratings_count'] is int)
          ? json['high_ratings_count'] as int
          : int.tryParse('${json['high_ratings_count']}') ?? 0,
    );
  }
}

class RatingBreakdown {
  const RatingBreakdown({
    this.count10 = 0,
    this.countHigh = 0,
    this.countMid = 0,
    this.countLow = 0,
  });

  final int count10;
  final int countHigh;
  final int countMid;
  final int countLow;

  factory RatingBreakdown.fromJson(Map<String, dynamic> json) {
    return RatingBreakdown(
      count10: int.tryParse('${json['count_10']}') ?? 0,
      countHigh: int.tryParse('${json['count_high']}') ?? 0,
      countMid: int.tryParse('${json['count_mid']}') ?? 0,
      countLow: int.tryParse('${json['count_low']}') ?? 0,
    );
  }
}

class CustomerReviewItem {
  const CustomerReviewItem({
    required this.jobCode,
    required this.customerName,
    required this.customerPhone,
    required this.deviceType,
    required this.feedbackRating,
    required this.feedbackComment,
    required this.feedbackDate,
  });

  final String jobCode;
  final String customerName;
  final String customerPhone;
  final String deviceType;
  final int feedbackRating;
  final String feedbackComment;
  final String feedbackDate;

  factory CustomerReviewItem.fromJson(Map<String, dynamic> json) {
    return CustomerReviewItem(
      jobCode: (json['job_code'] ?? '').toString(),
      customerName: (json['customer_name'] ?? 'Customer').toString(),
      customerPhone: (json['customer_phone'] ?? '').toString(),
      deviceType: (json['device_type'] ?? '').toString(),
      feedbackRating: (json['feedback_rating'] is int)
          ? json['feedback_rating'] as int
          : int.tryParse('${json['feedback_rating']}') ?? 0,
      feedbackComment: (json['feedback_comment'] ?? '').toString(),
      feedbackDate: (json['feedback_date'] ?? '').toString(),
    );
  }
}

class TechnicianFeedbackResponse {
  const TechnicianFeedbackResponse({
    required this.metrics,
    required this.ratingBreakdown,
    required this.reviews,
  });

  final TechnicianFeedbackMetrics metrics;
  final RatingBreakdown ratingBreakdown;
  final List<CustomerReviewItem> reviews;

  factory TechnicianFeedbackResponse.fromJson(Map<String, dynamic> json) {
    final metricsRaw = json['metrics'] is Map<String, dynamic>
        ? json['metrics'] as Map<String, dynamic>
        : <String, dynamic>{};
    final breakdownRaw = json['rating_breakdown'] is Map<String, dynamic>
        ? json['rating_breakdown'] as Map<String, dynamic>
        : <String, dynamic>{};
    final reviewsRaw = json['reviews'] is List ? json['reviews'] as List : [];

    return TechnicianFeedbackResponse(
      metrics: TechnicianFeedbackMetrics.fromJson(metricsRaw),
      ratingBreakdown: RatingBreakdown.fromJson(breakdownRaw),
      reviews: reviewsRaw
          .whereType<Map<String, dynamic>>()
          .map(CustomerReviewItem.fromJson)
          .toList(growable: false),
    );
  }
}
