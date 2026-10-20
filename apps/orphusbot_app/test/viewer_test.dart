import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/viewer.dart';

void main() {
  test('files open in the right viewer', () {
    expect(kindOf('Report.PDF'), Kind.pdf);
    expect(kindOf('clip.mp4'), Kind.video);
    expect(kindOf('note.m4a'), Kind.audio);
    expect(kindOf('logo.webp'), Kind.image);
    expect(kindOf('plan.md'), Kind.markdown);
    expect(kindOf('main.rs'), Kind.text);
    expect(kindOf('archive.zip'), Kind.other);
    expect(kindOf('no-extension'), Kind.other);
  });

  test('code is fenced with its language; Markdown stays as it is', () {
    expect(
      asMarkdown('a.rs', utf8.encode('fn main() {}')),
      '```rust\nfn main() {}\n```',
    );
    expect(asMarkdown('a.md', utf8.encode('# Hi')), '# Hi');
    // A fence inside the file can't close ours early.
    expect(asMarkdown('a.txt', utf8.encode('```x```')), startsWith('~~~~'));
  });
}
