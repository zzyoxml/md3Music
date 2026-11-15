import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../providers/listen_together_provider.dart';

/// 房间成员托盘。
class MembersSheet extends StatelessWidget {
  const MembersSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<ListenTogetherProvider>().session;
    final members = session?.members ?? const [];
    final cs = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      builder: (context, scrollController) => Center(
        // 横屏/平板下限宽居中，避免弹层被拉满整个屏幕宽度
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: cs.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              '房间成员（${members.length}）',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: members.isEmpty
                ? const Center(child: Text('暂无成员信息'))
                : ListView.builder(
                    controller: scrollController,
                    itemCount: members.length,
                    itemBuilder: (context, index) {
                      final member = members[index];
                      final isSelf = member.userId == session?.selfUserId;
                      final isOwner = member.userId == session?.ownerUserId;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundImage: member.avatar.isNotEmpty
                              ? NetworkImage(member.avatar)
                              : null,
                          child: member.avatar.isEmpty ? const Icon(Icons.person) : null,
                        ),
                        title: Text(member.nickname),
                        // 房主由详情接口注入（听众接口不含房主），徽标优先于「我」
                        trailing: isOwner || isSelf
                            ? Text(
                                isOwner ? (isSelf ? '房主·我' : '房主') : '我',
                                style: TextStyle(color: cs.primary, fontSize: 12),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
          ),
        ),
      ),
    );
  }
}
