---
name: new-craft-site
description: >-
  Agent-only procedure for spawning a fresh Craft CMS 5 site from the shared baseline.
  Use before spawning a fresh Craft site from the baseline.
  Owns the ddev setup, plugin installation, baseline seed application, and verification steps.
user-invocable: false
metadata:
  internal: true
---

# Spawn a fresh Craft CMS 5 site from the baseline

This skill creates a new Craft CMS 5 project with the shared baseline content model applied.
The baseline seed lives in this skill's `baseline/config/project/` directory as individual YAML files.
The captain preferences file and the project-ddev-migration skill own the ddev, admin, and plugin standards; defer to those for any detail not restated here.

## Baseline contents

The seed carries the shared content model extracted from the MBD x Bank Iowa cross-reference audit.
It includes:
- 3 sections (pages, testimonials, faqs)
- 44 entry types
- 240 fields (249 shared minus 9 orphaned by removed category groups and sections)
- 24 Neo block types (23 shared plus articles as a generic entry-listing block)
- 5 Neo block type groups
- 6 category groups (layout-only: breakpoint, columnDirection, columnWidth, siteColors, resourceCategory, services)
- 4 CKEditor configs
- 4 navigation navs (mainNav, footerNavigation, footerSubNavigation, tophatNavigation)
- 10 image transforms
- 2 global sets (siteControls with Logo/LogoWidth/FooterLogo/Favicon, siteStyles with full typography)

The Header Builder uses the multiColumn child-container pattern.
FAQs standardizes on UUID 032f8148.
Org-specific category groups (communities, countries, regions, jobTitles) are excluded.
The callout/banner block is excluded.
No project.yaml is included; the individual YAML files are the authoritative config and the target project keeps its own project.yaml.

## Steps

### 1. Create the project directory

```bash
mkdir -p <project-name>/app
cd <project-name>/app
```

### 2. Configure ddev

```bash
ddev config \
  --project-type=craftcms \
  --php-version=8.4 \
  --docroot=web \
  --database=mysql:8.0 \
  --project-name=<project-name>
```

### 3. Start ddev

```bash
ddev start
```

### 4. Install Craft

```bash
ddev composer create craftcms/craft:^5.0
```

The post-create-project-cmd may fail because it runs `craft install` without credentials.
That is expected; the install step runs separately below.

### 5. Install the standard plugins

```bash
ddev composer require \
  spicyweb/craft-neo \
  verbb/super-table \
  nystudio107/craft-seomatic \
  nystudio107/craft-retour \
  solspace/craft-freeform \
  putyourlightson/craft-blitz \
  spacecatninja/imager-x \
  craftcms/ckeditor \
  verbb/navigation \
  craftcms/feed-me \
  lukeyouell/craft-cookies \
  doublesecretagency/craft-cpcss \
  superbig/craft-google-cloud \
  craft-sendgrid/craft-sendgrid \
  two-rivers-marketing/craft-site-toolkit \
  two-rivers-marketing/craft-mcp \
  -W --no-interaction
```

Use `-W` (with-all-dependencies) to resolve version constraints across the Craft 5 ecosystem.
The exact version list is defined by fleet standards; this list matches the standard plugin set.

### 6. Set up the environment

```bash
cp .env.example .env
```

The `.env` needs `CRAFT_SECURITY_KEY` (generate with `ddev craft setup/security-key` if not already set).
Set `SYSTEM_EMAIL=support@2rm.com` as the dev default.
ddev injects DB connection variables automatically.

### 7. Install Craft and the plugins

```bash
ddev craft install \
  --username=admin \
  --email=support@2rm.com \
  --password=2rmdev \
  --site-name="<Project Name>"
```

Then install each plugin:

```bash
ddev craft plugin/install neo
ddev craft plugin/install super-table
ddev craft plugin/install ckeditor
ddev craft plugin/install navigation
ddev craft plugin/install freeform
ddev craft plugin/install seomatic
ddev craft plugin/install retour
ddev craft plugin/install blitz
ddev craft plugin/install imager-x
ddev craft plugin/install google-cloud
ddev craft plugin/install feed-me
ddev craft plugin/install cookies
ddev craft plugin/install cpcss
ddev craft plugin/install site-toolkit
ddev craft plugin/install craft-mcp
```

If a plugin install fails (not found, not compatible), skip it and note the failure.
The baseline config requires at minimum: neo, super-table, ckeditor, navigation, freeform, and seomatic.
The others are standard but do not have config in the seed.

### 8. Rebuild project config

```bash
ddev craft project-config/rebuild
```

This writes the fresh install's project config to individual YAML files with correct schema versions.

### 9. Apply the baseline seed

Copy only the individual config directories from the seed into the project's config/project/:

```bash
SEED="<path-to-this-skill>/baseline/config/project"
for dir in categoryGroups ckeditor entryTypes fields globalSets imageTransforms navigation neo sections; do
  rm -rf config/project/$dir
  cp -R "$SEED/$dir" config/project/$dir
done
```

Do NOT copy a project.yaml from the seed.
The target project keeps its own project.yaml generated in step 8.

Then apply:

```bash
ddev craft project-config/apply --force
```

### 10. Verify

```bash
ddev craft project-config/apply
```

This second apply must report "Finished applying changes" with no errors.

```bash
ddev craft project-config/diff
```

This must report "No pending project config YAML changes."

If either reports errors about missing UUIDs, a dangling reference exists in the seed.
Stop and investigate before continuing.

### 11. Scaffold templates

Create a minimal template structure:

```bash
mkdir -p templates/_layouts
```

Create `templates/_layouts/base.twig` and `templates/index.twig` following the project's template conventions.

## Completion criteria

- ddev site is running with all standard plugins installed
- `project-config/apply` reports zero errors
- `project-config/diff` reports no pending changes
- The Craft control panel is accessible and renders the sections, fields, and content builder
