{ inputs, ... }:
{
  flake.modules.aspects.games.imports = with inputs.self.modules.aspects; [
    anime-games-launcher
    games-hardware
    steam
  ];
}
