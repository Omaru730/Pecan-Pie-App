class AppConfig {
  // GitHub repository URL - update this with your actual repository
  static const String githubRepositoryUrl =
      'https://github.com/cogwheel0/luci-mobile';

  // GitHub issues URL
  static const String githubIssuesUrl = '$githubRepositoryUrl/issues';

  // Reviewer mode configuration
  static const String reviewerModeKey = 'reviewer_mode_enabled';
  static const String mockDataPath = 'assets/mock/';
  static const Duration reviewerModeActivationDuration = Duration(seconds: 5);
  static const String reviewerModeWatermark = 'Reviewer Mode';

  // added setup scree 
  static const String defaultAdminUsername = 'admin';
  static const String defaultAdminPassword = 'admin12345';
  static const String setupCompleteKey = 'setup_complete';
}