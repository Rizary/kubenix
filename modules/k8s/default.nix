{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.kubernetes;

  removeKubenixOptions = filterAttrs (name: attr: name != "kubenix");

  getDefaults = resource: group: version: kind:
    catAttrs "default" (filter (default:
      (resource == null || default.resource == null || default.resource == resource) &&
      (default.group == null || default.group == group) &&
      (default.version == null || default.version == version) &&
      (default.kind == null || default.kind == kind)
    ) cfg.api.defaults);

  moduleToAttrs = value:
    if isAttrs value
    then mapAttrs (n: v: moduleToAttrs v) (filterAttrs (n: v: !(hasPrefix "_" n) && v != null) value)

    else if isList value
    then map (v: moduleToAttrs v) value

    else value;

  flattenResources = resources: flatten (
    mapAttrsToList (groupName: versions:
      mapAttrsToList (versionName: kinds:
        builtins.trace versionName kinds
      ) versions
    ) resources
  );

  toKubernetesList = resources: {
    kind = "List";
    apiVersion = "v1";
    items = resources;
  };

  apiOptions = { config, ... }: {
    options = {
      definitions = mkOption {
        description = "Attribute set of kubernetes definitions";
      };

      defaults = mkOption {
        description = "Kubernetes defaults to apply to resources";
        type = types.listOf (types.submodule ({config, ...}: {
          options = {
            resource = mkOption {
              description = "Resource to apply default to (all by default)";
              type = types.nullOr types.str;
              default = null;
            };

            group = mkOption {
              description = "Group to apply default to (all by default)";
              type = types.nullOr types.str;
              default = null;
            };

            version = mkOption {
              description = "Version to apply default to (all by default)";
              type = types.nullOr types.str;
              default = null;
            };

            kind = mkOption {
              description = "Kind to apply default to (all by default)";
              type = types.nullOr types.str;
              default = null;
            };

            default = mkOption {
              description = "Default to apply";
              type = types.unspecified;
              default = {};
            };
          };
        }));
        default = [];
      };

      resources = mkOption {
        type = types.listOf (types.submodule {
          options = {
            group = mkOption {
              description = "Resoruce group";
              type = types.str;
            };

            version = mkOption {
              description = "Resoruce version";
              type = types.str;
            };

            kind = mkOption {
              description = "Resource kind";
              type = types.str;
            };

            resource = mkOption {
              description = "Resource name";
              type = type.str;
            };
          };
        });
        default = [];
      };
    };
  };

  indexOf = lst: value:
    head (filter (v: v != -1) (imap0 (i: v: if v == value then i else -1) lst));
in {
  imports = [./lib.nix];

  options.kubernetes.version = mkOption {
    description = "Kubernetes version to use";
    type = types.enum ["1.7" "1.8" "1.9" "1.10" "1.11" "1.12" "1.13"];
    default = "1.13";
  };

  options.kubernetes.resourceOrder = mkOption {
    description = "Preffered resource order";
    type = types.listOf types.str;
    default = [
      "CustomResourceDefinition"
      "Namespace"
    ];
  };

  options.kubernetes.api = mkOption {
    type = types.submodule {
      imports = [
        (./generated + ''/v'' + cfg.version + ".nix")
        apiOptions
      ] ++ (map (cr: {config, ...}: {
        options.${cr.group}.${cr.version}.${cr.kind} = mkOption {
          description = cr.description;
          type = types.attrsOf (types.submodule ({name, ...}: {
            imports = getDefaults cr.resource cr.group cr.version cr.kind;
            options = {
              apiVersion = mkOption {
                description = "APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/api-conventions.md#resources";
                type = types.nullOr types.str;
              };

              kind = mkOption {
                description = "Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/api-conventions.md#types-kinds";
                type = types.nullOr types.str;
              };

              metadata = mkOption {
                description = "Standard object metadata; More info: https://git.k8s.io/community/contributors/devel/api-conventions.md#metadata.";
                type = types.nullOr (types.submodule config.definitions."io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta");
              };

              spec = mkOption {
                description = "Module spec";
                type = types.submodule cr.module;
                default = {};
              };
            };

            config = {
              apiVersion = mkOptionDefault "${cr.group}/${cr.version}";
              kind = mkOptionDefault cr.kind;
              metadata.name = mkOptionDefault name;
            };
          }));
          default = {};
        };
      }) cfg.customResources);
    };
    default = {};
  };

  options.kubernetes.customResources = mkOption {
    default = [];
    description = "List of custom resource definitions to make API for";
    type = types.listOf (types.submodule ({config, ...}: {
      options = {
        group = mkOption {
          description = "Custom resource definition group";
          type = types.str;
        };

        version = mkOption {
          description = "Custom resource definition version";
          type = types.str;
        };

        kind = mkOption {
          description = "Custom resource definition kind";
          type = types.str;
        };

        resource = mkOption {
          description = "Custom resource definition resource name";
          type = types.nullOr types.str;
          default = null;
        };

        description = mkOption {
          description = "Custom resource definition description";
          type = types.str;
          default = "";
        };

        module = mkOption {
          description = "Custom resource definition module";
          default = types.unspecified;
        };
      };
    }));
  };

  config.kubernetes.api.resources = map (cr: {
    inherit (cr) group version kind resource;
  }) cfg.customResources;

  options.kubernetes.objects = mkOption {
    description = "Attribute set of kubernetes objects";
    type = types.listOf types.attrs;
    apply = items: sort (r1: r2:
      if elem r1.kind cfg.resourceOrder && elem r2.kind cfg.resourceOrder
      then indexOf cfg.resourceOrder r1.kind < indexOf cfg.resourceOrder r2.kind
      else if elem r1.kind cfg.resourceOrder then true else false
    ) (moduleToAttrs (unique items));
    default = [];
  };

  config.kubernetes.objects = flatten (map (gvk:
    mapAttrsToList (name: resource:
      removeKubenixOptions (moduleToAttrs resource)
    ) cfg.api.${gvk.group}.${gvk.version}.${gvk.kind}
  ) cfg.api.resources);

  options.kubernetes.generated = mkOption {
    type = types.attrs;
    description = "Generated json file";
  };

  config.kubernetes.generated = let
    kubernetesList = toKubernetesList cfg.objects;

    hashedList = kubernetesList // {
      labels."kubenix/build" = cfg.hash;
      items = map (resource: recursiveUpdate resource {
        metadata.labels."kubenix/build" = cfg.hash;
      }) kubernetesList.items;
    };
  in hashedList;

  options.kubernetes.hash = mkOption {
    type = types.str;
    description = "Output hash";
  };

  config.kubernetes.hash = builtins.hashString "sha1" (builtins.toJSON cfg.objects);
}