class AppConfig {
  // GitHub repository URL - update this with your actual repository
  static const String githubRepositoryUrl =
      'https://github.com/Omaru730/Pecan-Pie-App';

  // GitHub issues URL
  static const String githubIssuesUrl = '$githubRepositoryUrl/issues';

  // First-time setup wizard configuration - set once user finishes setup.
  static const String setupCompleteKey = 'setup_complete';

  // The real account on the device. Setup logs in ass this first.
  static const String rootUsername = 'root';

  // Suggested login name shown in setup screen. Can be changed by the user.
  static const String defaultAdminUsername = 'Admin';

  // The default password. It MUST match the root's actual password on the 
  // device, or else the first login in setup will fail
  static const String defaultAdminPassword = 'password';


  // Name of the alias login section in /etc/config/rcpd
  static const String aliasSectionName = 'pecan_alias';

  // Makes the alias login root's password. 'r' must be before the quotes, or 
  // else Dart will try to read $p and $root as variables.
  static const String aliasPasswordRef = r'$p$root';

  // Set to true only if the alias works after an rcpd restart and not before.
  // Leave false if the alias logged on immediately.
  static const bool aliasNeedsRpcdRestart = false;

  // Reviewer mode configuration 
  static const String reviewerModeKey = 'reviewer_mode_enabled';
  static const String mockDataPath = 'assets/mock/';
  static const Duration reviewerModeActivationDuration = Duration(seconds: 5);
  static const String reviewerModeWatermark = 'Reviewer Mode';

}