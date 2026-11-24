enum GroupPlatform {
  whatsApp,
  messenger,
  telegram,
  discord,
  twitch,
  drive,
  other,
}

class WhatsAppGroup {
  final String id;
  final String title;
  final String carrera;
  final String curso;
  final String section;
  final String link;
  final String description;
  final String? userId;
  final String authorAlias;
  final int? avatarColorIndex;
  final int? avatarIconIndex;
  final int upvotes;
  final int reportedCount;
  final int sharesCount;
  final DateTime createdAt;
  final String? imageUrl;
  final int moderationStatus;
  final bool isUpvotedByMe;
  final bool isMine;
  final GroupPlatform? explicitPlatform;

  WhatsAppGroup({
    required this.id,
    required this.title,
    required this.carrera,
    required this.curso,
    required this.section,
    required this.link,
    required this.description,
    this.userId,
    required this.authorAlias,
    this.avatarColorIndex,
    this.avatarIconIndex,
    required this.upvotes,
    required this.reportedCount,
    this.sharesCount = 0,
    required this.createdAt,
    this.imageUrl,
    this.moderationStatus = 0,
    this.isUpvotedByMe = false,
    this.isMine = false,
    this.explicitPlatform,
  });

  static String platformToString(GroupPlatform p) {
    switch (p) {
      case GroupPlatform.whatsApp:
        return 'whatsapp';
      case GroupPlatform.messenger:
        return 'messenger';
      case GroupPlatform.telegram:
        return 'telegram';
      case GroupPlatform.discord:
        return 'discord';
      case GroupPlatform.twitch:
        return 'twitch';
      case GroupPlatform.drive:
        return 'drive';
      case GroupPlatform.other:
        return 'otro';
    }
  }

  static GroupPlatform stringToPlatform(String? p, String link) {
    if (p != null && p.isNotEmpty) {
      switch (p.toLowerCase()) {
        case 'whatsapp':
          return GroupPlatform.whatsApp;
        case 'messenger':
          return GroupPlatform.messenger;
        case 'telegram':
          return GroupPlatform.telegram;
        case 'discord':
          return GroupPlatform.discord;
        case 'twitch':
          return GroupPlatform.twitch;
        case 'drive':
          return GroupPlatform.drive;
        case 'otro':
          return GroupPlatform.other;
      }
    }
    final lower = link.toLowerCase();
    if (lower.contains('chat.whatsapp.com') || lower.contains('wa.me')) {
      return GroupPlatform.whatsApp;
    }
    if (lower.contains('://m.me/') ||
        lower.contains('://www.m.me/') ||
        lower.contains('messenger.com')) {
      return GroupPlatform.messenger;
    }
    if (lower.contains('t.me') || lower.contains('telegram.me')) {
      return GroupPlatform.telegram;
    }
    if (lower.contains('discord.gg') || lower.contains('discord.com')) {
      return GroupPlatform.discord;
    }
    if (lower.contains('twitch.tv')) {
      return GroupPlatform.twitch;
    }
    if (lower.contains('drive.google.com') ||
        lower.contains('docs.google.com')) {
      return GroupPlatform.drive;
    }
    return GroupPlatform.other;
  }

  GroupPlatform get platform => explicitPlatform ?? stringToPlatform(null, link);

  WhatsAppGroup copyWith({
    String? id,
    String? title,
    String? carrera,
    String? curso,
    String? section,
    String? link,
    String? description,
    String? userId,
    String? authorAlias,
    int? avatarColorIndex,
    int? avatarIconIndex,
    int? upvotes,
    int? reportedCount,
    int? sharesCount,
    DateTime? createdAt,
    String? imageUrl,
    int? moderationStatus,
    bool? isUpvotedByMe,
    bool? isMine,
  }) {
    return WhatsAppGroup(
      id: id ?? this.id,
      title: title ?? this.title,
      carrera: carrera ?? this.carrera,
      curso: curso ?? this.curso,
      section: section ?? this.section,
      link: link ?? this.link,
      description: description ?? this.description,
      userId: userId ?? this.userId,
      authorAlias: authorAlias ?? this.authorAlias,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      avatarIconIndex: avatarIconIndex ?? this.avatarIconIndex,
      upvotes: upvotes ?? this.upvotes,
      reportedCount: reportedCount ?? this.reportedCount,
      sharesCount: sharesCount ?? this.sharesCount,
      createdAt: createdAt ?? this.createdAt,
      imageUrl: imageUrl ?? this.imageUrl,
      moderationStatus: moderationStatus ?? this.moderationStatus,
      isUpvotedByMe: isUpvotedByMe ?? this.isUpvotedByMe,
      isMine: isMine ?? this.isMine,
    );
  }

  factory WhatsAppGroup.fromMap(
    Map<String, dynamic> map, {
    bool isUpvotedByMe = false,
  }) {
    return WhatsAppGroup(
      id: map['id']?.toString() ?? '',
      title: map['title'] ?? '',
      carrera: map['carrera'] ?? 'todas',
      curso: map['curso'] ?? '',
      section: map['section'] ?? 'Sección Única',
      link: map['link'] ?? '',
      description: map['description'] ?? '',
      userId: null,
      authorAlias: map['author_alias'] ?? 'Estudiante USAC',
      avatarColorIndex: map['avatar_color_index'] is int
          ? map['avatar_color_index'] as int
          : int.tryParse(map['avatar_color_index']?.toString() ?? ''),
      avatarIconIndex: map['avatar_icon_index'] is int
          ? map['avatar_icon_index'] as int
          : int.tryParse(map['avatar_icon_index']?.toString() ?? ''),
      upvotes: (map['upvotes'] is int)
          ? map['upvotes']
          : int.tryParse(map['upvotes']?.toString() ?? '0') ?? 0,
      reportedCount: (map['reported_count'] is int)
          ? map['reported_count']
          : int.tryParse(map['reported_count']?.toString() ?? '0') ?? 0,
      sharesCount: (map['shares_count'] is int)
          ? map['shares_count']
          : int.tryParse(map['shares_count']?.toString() ?? '0') ?? 0,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      imageUrl: map['image_url'],
      moderationStatus: (map['moderation_status'] is int)
          ? map['moderation_status']
          : int.tryParse(map['moderation_status']?.toString() ?? '0') ?? 0,
      isUpvotedByMe: isUpvotedByMe,
      isMine: map['is_mine'] == true,
      explicitPlatform: map['platform'] != null &&
              map['platform'].toString().trim().isNotEmpty
          ? stringToPlatform(map['platform'].toString(), map['link'] ?? '')
          : null,
    );
  }

  Map<String, dynamic> toInsertMap() {
    return {
      'title': title,
      'carrera': carrera,
      'curso': curso,
      'section': section,
      'link': link,
      'platform': platformToString(platform),
      'description': description,
      'user_id': userId,
      'author_alias': authorAlias,
      'upvotes': upvotes,
      'reported_count': reportedCount,
      'shares_count': sharesCount,
      'image_url': imageUrl,
      'moderation_status': moderationStatus,
    };
  }
}
