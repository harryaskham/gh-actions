{
  description = "Self-test flake for harryaskham/gh-actions FlakeHub workflows";

  # No inputs: two tiny /bin/sh derivations whose store paths change with every
  # commit, so each run uploads fresh paths and the verify job proves FlakeHub
  # Cache serves a two-path closure that no public cache has.
  outputs = {self}: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    rev = self.rev or self.dirtyRev or "unknown";
    forAllSystems = f:
      builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        })
        systems);
  in {
    packages = forAllSystems (system: rec {
      dep = derivation {
        name = "gh-actions-selftest-dep";
        inherit system;
        builder = "/bin/sh";
        args = ["-c" "echo ${rev} > $out"];
      };
      top = derivation {
        name = "gh-actions-selftest";
        inherit system;
        builder = "/bin/sh";
        args = ["-c" "echo ${dep} > $out"];
      };
      default = top;
    });
  };
}
