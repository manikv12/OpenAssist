export interface SlashCommandLike<TTone extends string = string> {
  id: string;
  label: string;
  subtitle: string;
  groupId: string;
  groupLabel: string;
  groupTone: TTone;
  groupOrder: number;
  searchKeywords?: string[];
}

export interface SlashCommandGroupLike<
  TCommand extends SlashCommandLike<TTone>,
  TTone extends string = string,
> {
  id: string;
  label: string;
  tone: TTone;
  order: number;
  commands: TCommand[];
}

export function matchesSlashCommand<TTone extends string>(
  command: SlashCommandLike<TTone>,
  query: string
): boolean {
  const haystack = [
    command.id,
    command.label,
    command.subtitle,
    command.groupLabel,
    ...(command.searchKeywords ?? []),
  ]
    .join(" ")
    .toLowerCase();

  return haystack.includes(query);
}

export function groupSlashCommands<
  TCommand extends SlashCommandLike<TTone>,
  TTone extends string = string,
>(commands: TCommand[]): SlashCommandGroupLike<TCommand, TTone>[] {
  const groups = new Map<string, SlashCommandGroupLike<TCommand, TTone>>();

  commands.forEach((command) => {
    const existingGroup = groups.get(command.groupId);
    if (existingGroup) {
      existingGroup.commands.push(command);
      return;
    }

    groups.set(command.groupId, {
      id: command.groupId,
      label: command.groupLabel,
      tone: command.groupTone,
      order: command.groupOrder,
      commands: [command],
    });
  });

  return [...groups.values()].sort((left, right) => left.order - right.order);
}
