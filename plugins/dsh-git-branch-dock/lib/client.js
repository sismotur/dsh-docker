/**
 * Prebuilt dsh client module (ModuleLoader factory).
 * Footer: `<project> @ <branch> ---` then stats pills.
 * Branch comes from the mounted /workspace project repo, not dsh-docker.
 */
window.__ModuleLoader__.load({
  id: "dsh-git-branch-dock",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    var React = require("react");
    var jsxRuntime = require("react/jsx-runtime");
    var _jsx = jsxRuntime.jsx;
    var _jsxs = jsxRuntime.jsxs;

    var ENDPOINT = "/git-branch-dock/branch";
    var POLL_MS = 8000;

    var rootStyle = {
      display: "inline-flex",
      alignItems: "center",
      gap: "0.35em",
      fontSize: "12px",
      lineHeight: 1.2,
      opacity: 0.85,
      whiteSpace: "nowrap",
      userSelect: "none",
      marginRight: "0.25em",
    };

    var labelStyle = {
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
      fontWeight: 600,
    };

    var sepStyle = {
      opacity: 0.55,
      fontWeight: 400,
    };

    function BranchPill() {
      var _s = React.useState(null);
      var label = _s[0];
      var setLabel = _s[1];
      var _s2 = React.useState(null);
      var branch = _s2[0];
      var setBranch = _s2[1];
      var _s3 = React.useState(null);
      var project = _s3[0];
      var setProject = _s3[1];
      var _s4 = React.useState(" --- ");
      var sep = _s4[0];
      var setSep = _s4[1];

      React.useEffect(function () {
        var cancelled = false;
        var timer = null;

        var load = function () {
          return fetch(ENDPOINT, { method: "GET", credentials: "same-origin" })
            .then(function (res) {
              if (!res.ok) throw new Error("HTTP " + res.status);
              return res.json();
            })
            .then(function (data) {
              if (cancelled) return;
              var br = typeof data.branch === "string" && data.branch ? data.branch : null;
              var proj = typeof data.project === "string" && data.project ? data.project : null;
              var lab =
                typeof data.label === "string" && data.label
                  ? data.label
                  : br
                    ? proj
                      ? proj + " @ " + br
                      : br
                    : null;
              setBranch(br);
              setProject(proj);
              setLabel(lab);
              if (typeof data.separator === "string") setSep(data.separator);
            })
            .catch(function () {
              if (!cancelled) {
                setBranch(null);
                setProject(null);
                setLabel(null);
              }
            });
        };

        load();
        timer = setInterval(load, POLL_MS);
        return function () {
          cancelled = true;
          if (timer) clearInterval(timer);
        };
      }, []);

      if (!label) return null;

      var tip = project ? "Project " + project + " · branch " + (branch || "") : "Git branch: " + (branch || label);

      return _jsxs("span", {
        style: rootStyle,
        title: tip,
        "data-git-branch-dock": true,
        "data-branch": branch || "",
        "data-project": project || "",
        children: [
          _jsx("span", { style: labelStyle, children: label }),
          _jsx("span", { style: sepStyle, "aria-hidden": true, children: sep }),
        ],
      });
    }

    var inject = ["slots"];

    function apply(ctx) {
      ctx.slots.inject("conversation.composer.dock", function () {
        return ctx.slots.register(
          {
            name: "conversation.composer.dock",
            id: "git-branch",
            order: -10,
          },
          BranchPill,
        );
      });
    }

    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  },
});
