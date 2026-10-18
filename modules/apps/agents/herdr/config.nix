{ inputs, ... }:
{
  flake.modules.homeManager.herdr.programs.herdr = {
    enable = true;
    reviewr.enable = true;
    settings = {
      onboarding = false;
      session.resume_agents_on_restore = true;
      theme.name = "terminal";
      ui.toast.delivery = "system";
    };
  };
}
