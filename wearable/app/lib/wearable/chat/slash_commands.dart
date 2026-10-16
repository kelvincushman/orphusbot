// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Slash-command registry and expander for the Boardroom chat composer.
//
// Pure, side-effect-free — safe to unit-test without Flutter bindings.

/// A single slash command descriptor.
class SlashCommand {
  final String name;        // e.g. "clear"
  final String description; // short one-liner shown in the menu
  final bool isLocal;       // true → handled in-app, not forwarded to Wearable

  const SlashCommand({
    required this.name,
    required this.description,
    this.isLocal = false,
  });
}

/// All supported slash commands, in display order.
const List<SlashCommand> kSlashCommands = [
  SlashCommand(name: 'clear',    description: 'Clear the current chat thread',         isLocal: true),
  SlashCommand(name: 'help',     description: 'Show available commands',                isLocal: true),
  SlashCommand(name: 'email',    description: 'Draft an email (e.g. /email <details>)'),
  SlashCommand(name: 'research', description: 'Research a topic'),
  SlashCommand(name: 'remind',   description: 'Set a reminder'),
  SlashCommand(name: 'note',     description: 'Make a note'),
  SlashCommand(name: 'blog',     description: 'Write a blog post'),
];

/// Result of parsing a slash command from raw composer text.
class SlashResult {
  /// Non-null for local commands (/clear, /help). Value is the command name.
  final String? localAction;

  /// Non-null for prompt shortcuts — the expanded natural-language string
  /// that should be forwarded to Wearable via sendMessage().
  final String? prompt;

  const SlashResult._({this.localAction, this.prompt});
}

/// Parse [raw] text from the composer and decide what to do.
///
/// Returns:
///  - `SlashResult(localAction: "clear")` for `/clear`
///  - `SlashResult(localAction: "help")`  for `/help`
///  - `SlashResult(prompt: "…expanded…")` for prompt shortcuts
///  - `null` when the text is not a recognized slash command (plain text)
///
/// Matching is case-insensitive. Leading/trailing whitespace is ignored.
/// If the command name is recognized but has no args where args are needed
/// (e.g. `/email` alone), the expansion still works but the expanded prompt
/// will be minimal — the server handles empty bodies gracefully.
SlashResult? expandSlashCommand(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('/')) return null;

  // Split on first whitespace: "/email hello world" → ["email", "hello world"]
  final withoutSlash = trimmed.substring(1);
  final spaceIdx = withoutSlash.indexOf(' ');
  final cmd = spaceIdx < 0
      ? withoutSlash.toLowerCase()
      : withoutSlash.substring(0, spaceIdx).toLowerCase();
  final args = spaceIdx < 0 ? '' : withoutSlash.substring(spaceIdx + 1).trim();

  switch (cmd) {
    case 'clear':
      return const SlashResult._(localAction: 'clear');
    case 'help':
      return const SlashResult._(localAction: 'help');
    case 'email':
      return SlashResult._(
        prompt: args.isEmpty
            ? 'Draft an email and put it in my drafts'
            : 'Draft an email: $args and put it in my drafts',
      );
    case 'research':
      return SlashResult._(
        prompt: args.isEmpty ? 'Research this topic' : 'Research: $args',
      );
    case 'remind':
      return SlashResult._(
        prompt: args.isEmpty ? 'Remind me' : 'Remind me to $args',
      );
    case 'note':
      return SlashResult._(
        prompt: args.isEmpty ? 'Make a note' : 'Make a note: $args',
      );
    case 'blog':
      return SlashResult._(
        prompt: args.isEmpty
            ? 'Write a blog post'
            : 'Write a blog post: $args',
      );
    default:
      return null; // unrecognized → treat as plain text
  }
}

/// Filter [kSlashCommands] by [query] (the text after the leading "/").
/// Returns commands whose name starts with [query] (case-insensitive).
/// Returns all commands when [query] is empty.
List<SlashCommand> filterCommands(String query) {
  final q = query.toLowerCase();
  if (q.isEmpty) return kSlashCommands;
  return kSlashCommands.where((c) => c.name.startsWith(q)).toList();
}
