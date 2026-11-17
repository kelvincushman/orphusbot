import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/chat.dart';

void main() {
  test('a send card shows the whole email and its account', () {
    final send = {
      'action': 'send',
      'account': 'work',
      'to': ['a@example.com', 'b@example.com'],
      'bcc': ['c@example.com'],
      'subject': 'Lunch',
      'body': 'Friday?',
    };
    expect(mailTitle('Inbox', send), 'Inbox wants to send an email from work');
    expect(
      mailDetail(send),
      'From account: work\nTo: a@example.com, b@example.com\n'
      'Bcc: c@example.com\nSubject: Lunch\n\nFriday?',
    );
  });

  test('other changes say what they touch', () {
    expect(
      mailTitle('Inbox', {
        'action': 'move',
        'account': 'personal',
        'ids': ['1', '2'],
        'to_folder': 'Archive',
      }),
      'Inbox wants to move 2 emails from INBOX to Archive (personal)',
    );
    final delete = {
      'action': 'delete',
      'account': 'work',
      'folder': 'Spam',
      'ids': ['9'],
    };
    expect(
      mailTitle('Inbox', delete),
      'Inbox wants to delete 1 email in Spam (work)',
    );
    expect(mailDetail(delete), 'Envelope ids: 9');
  });
}
