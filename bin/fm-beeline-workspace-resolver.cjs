const Module = require('module');
const path = require('path');

const root = process.env.FM_BEELINE_NODE_MODULES;
if (!root) throw new Error('FM_BEELINE_NODE_MODULES is required');

const originalResolveFilename = Module._resolveFilename;
const workspaceParent = new Module(path.join(path.dirname(root), '.fm-beeline-resolver-entry.cjs'));
workspaceParent.filename = path.join(path.dirname(root), '.fm-beeline-resolver-entry.cjs');
workspaceParent.paths = [root];

Module._resolveFilename = function (request, parent, isMain, options) {
  if (/^@beeline\/[^/]+(?:\/.*)?$/.test(request)) {
    return Reflect.apply(originalResolveFilename, this, [request, workspaceParent, isMain, options]);
  }
  return Reflect.apply(originalResolveFilename, this, [request, parent, isMain, options]);
};
