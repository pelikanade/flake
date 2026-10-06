{ lib, ... }:
let
  # A skill is a directory containing a SKILL.md, and a source keeps its skills
  # in one of the generic locations that the skills CLI searches. Dot
  # directories are skipped because they hold per-agent copies of the same
  # skills.
  findSkills =
    directory:
    if !(builtins.pathExists directory) then
      [ ]
    else if builtins.pathExists (directory + "/SKILL.md") then
      [ directory ]
    else
      let
        entries = builtins.readDir directory;
      in
      lib.concatMap (
        name:
        lib.optionals (entries.${name} == "directory" && !(lib.hasPrefix "." name)) (
          findSkills (directory + "/${name}")
        )
      ) (builtins.attrNames entries);

  # A source may instead publish its skills through the plugin manifest that
  # the skills CLI reads, which is how an upstream marks the skills it
  # considers released.
  publishedSkills =
    source:
    let
      manifest = source + "/.claude-plugin/plugin.json";
    in
    if builtins.pathExists manifest then
      map (path: source + "/" + lib.removePrefix "/" (lib.removePrefix "./" path)) (
        (builtins.fromJSON (builtins.readFile manifest)).skills or [ ]
      )
    else
      [ ];

  # The frontmatter is the only place that a lone Markdown skill file carries
  # its name.
  declaredName =
    file:
    let
      line = lib.findFirst (line: lib.hasPrefix "name:" line) null (
        lib.splitString "\n" (builtins.readFile file)
      );
      unquoted = text: lib.removePrefix "\"" (lib.removeSuffix "\"" text);
    in
    if line == null then null else unquoted (lib.trim (lib.removePrefix "name:" line));

  # Skills of one source, keyed by the name that agents look up. The name
  # labels the link that agents read, so it must not carry the store path
  # context of the directory it was derived from.
  skillsOf =
    source:
    if lib.pathIsDirectory source then
      let
        published = publishedSkills source;
        directories =
          if published != [ ] then
            published
          else
            lib.concatMap (subdirectory: findSkills (source + subdirectory)) [
              "/skills"
              "/.agents/skills"
            ];
      in
      lib.listToAttrs (
        map (
          directory:
          lib.nameValuePair (builtins.unsafeDiscardStringContext (baseNameOf (toString directory))) directory
        ) directories
      )
    else
      let
        name = declaredName source;
      in
      lib.optionalAttrs (name != null) { ${name} = source; };

  # The Markdown files beside this module are the skills this repository adds
  # itself; upstream sources are pinned per consumer.
  localSkills = lib.mapAttrsToList (name: _: ./. + "/${name}") (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) (builtins.readDir ./.)
  );
in
{
  flake.modules.homeManager.skills =
    { config, pkgs, ... }:
    let
      cfg = config.skills;

      skillSources = lib.zipAttrs (map skillsOf cfg.install);

      # Skill name to the source directory that holds it.
      skills = lib.mapAttrs (_: paths: lib.head paths) skillSources;

      duplicated = lib.attrNames (lib.filterAttrs (_: paths: builtins.length paths > 1) skillSources);

      empty = builtins.filter (source: skillsOf source == { }) cfg.install;

      # A lone Markdown file becomes a skill directory in the store, so installed
      # skills all have the shape agents expect.
      skillDirectory =
        name: source:
        if lib.pathIsDirectory source then
          source
        else
          pkgs.runCommand "skill-${lib.strings.sanitizeDerivationName name}" { } ''
            mkdir -p $out
            cp ${source} $out/SKILL.md
          '';
    in
    {
      options.skills.install = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        example = lib.literalExpression ''
          [
            (builtins.fetchTree {
              type = "github";
              owner = "jakubkrehel";
              repo = "skills";
              rev = "267330e1adfc66a718fb65fa6918c1f06d0a689e";
              narHash = "sha256-N0ip9CCwXy1x7707waHQRlitoMT23Yu9NpCA4NFzXmA=";
            })
          ]
        '';
        description = ''
          Skill sources to install for the user. Each entry is a fetched source
          tree or a single Markdown skill file, and every skill the source provides is
          linked into `$HOME/.agents/skills/<name>`, the generic location
          shared by agents that read the `.agents/skills` convention.
          Agent-specific skill directories are not written.

          A source tree keeps its skills in directories containing a SKILL.md
          below `skills/` or `.agents/skills/`, or publishes them through
          `.claude-plugin/plugin.json`. A lone skill file is installed under the
          name its frontmatter declares.
        '';
      };

      config = {
        # Local skills are the Markdown files beside this module; every source
        # an upstream publishes is pinned by revision and tree hash here.
        skills.install = localSkills;

        assertions = [
          {
            assertion = empty == [ ];
            message = ''
              these `skills.install` sources provide no skills:
              ${lib.concatMapStringsSep "\n" (source: "- ${toString source}") empty}
            '';
          }
          {
            assertion = duplicated == [ ];
            message = ''
              these skills are provided by more than one source, so they cannot
              be installed by name:
              ${lib.concatStringsSep ", " duplicated}
            '';
          }
        ];

        home.file = lib.listToAttrs (
          map (name: {
            name = ".agents/skills/${name}";
            value.source = skillDirectory name skills.${name};
          }) (builtins.attrNames skills)
        );
      };
    };
}
