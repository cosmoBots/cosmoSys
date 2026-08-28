(function() {
  function initDocumentReferenceSearch() {
    var search = document.getElementById('cosmosys-document-search');
    var select = document.getElementById('cosmosys-catalog-ref-document');
    if (!search || !select || search.dataset.cosmosysBound === '1') return;
    search.dataset.cosmosysBound = '1';
    search.addEventListener('input', function() {
      var query = search.value.toLowerCase().trim();
      Array.prototype.forEach.call(select.options, function(option) {
        option.hidden = query.length > 0 && option.text.toLowerCase().indexOf(query) === -1;
      });
      var first = Array.prototype.find.call(select.options, function(option) { return !option.hidden; });
      if (first) select.value = first.value;
    });
  }

  function collapseStorageKey() {
    var treeView = document.querySelector('.cosmosys-tree-view[data-cosmosys-tree]');
    if (!treeView) return null;

    return ['cosmosys', 'collapsed', window.location.pathname, treeView.dataset.cosmosysTree].join(':');
  }

  function readCollapsedState() {
    var key = collapseStorageKey();
    if (!key) return new Set();

    try {
      return new Set(JSON.parse(localStorage.getItem(key) || '[]'));
    } catch (_error) {
      return new Set();
    }
  }

  function writeCollapsedState(collapsedIds) {
    var key = collapseStorageKey();
    if (!key) return;

    localStorage.setItem(key, JSON.stringify(Array.from(collapsedIds)));
  }

  function syncToggleButton(item, expanded) {
    var button = item.querySelector(':scope > .cosmosys-tree-node [data-tree-toggle="node"]');
    if (!button) return;

    button.setAttribute('aria-expanded', expanded ? 'true' : 'false');
    button.textContent = expanded ? '-' : '+';
  }

  function setCollapsed(item, collapsed) {
    item.classList.toggle('cosmosys-collapsed', collapsed);
    syncToggleButton(item, !collapsed);
  }

  function rememberCollapsed(item, collapsed) {
    var issueId = item && item.dataset ? item.dataset.issueId : null;
    if (!issueId) return;

    var collapsedIds = readCollapsedState();
    if (collapsed) {
      collapsedIds.add(issueId);
    } else {
      collapsedIds.delete(issueId);
    }
    writeCollapsedState(collapsedIds);
  }

  function restoreCollapsedState() {
    var collapsedIds = readCollapsedState();
    if (collapsedIds.size === 0) return;

    document.querySelectorAll('.cosmosys-tree-view li[data-issue-id]').forEach(function(item) {
      if (!item.querySelector(':scope > ul.cosmosys-tree-children')) return;
      setCollapsed(item, collapsedIds.has(item.dataset.issueId));
    });
  }

  function initTreeToggles() {
    document.querySelectorAll('[data-tree-toggle="node"]').forEach(function(button) {
      if (button.dataset.cosmosysBound === '1') return;
      button.dataset.cosmosysBound = '1';
      button.addEventListener('click', function() {
        var item = button.closest('li');
        if (!item) return;
        var collapsed = !item.classList.contains('cosmosys-collapsed');
        setCollapsed(item, collapsed);
        rememberCollapsed(item, collapsed);
      });
    });
  }

  function toggleAll(expand) {
    var collapsedIds = readCollapsedState();
    document.querySelectorAll('.cosmosys-tree-view li').forEach(function(item) {
      var hasChildren = item.querySelector(':scope > ul.cosmosys-tree-children');
      if (!hasChildren) return;
      setCollapsed(item, !expand);
      if (item.dataset && item.dataset.issueId) {
        if (expand) {
          collapsedIds.delete(item.dataset.issueId);
        } else {
          collapsedIds.add(item.dataset.issueId);
        }
      }
    });
    writeCollapsedState(collapsedIds);
  }

  function initTreeToolbar() {
    document.querySelectorAll('[data-tree-target="expand-all"]').forEach(function(button) {
      if (button.dataset.cosmosysBound === '1') return;
      button.dataset.cosmosysBound = '1';
      button.addEventListener('click', function() { toggleAll(true); });
    });
    document.querySelectorAll('[data-tree-target="collapse-all"]').forEach(function(button) {
      if (button.dataset.cosmosysBound === '1') return;
      button.dataset.cosmosysBound = '1';
      button.addEventListener('click', function() { toggleAll(false); });
    });
  }

  function isDescendant(targetNode, draggedNode) {
    if (!targetNode || !draggedNode) return false;
    return !!targetNode.closest('li[data-issue-id="' + draggedNode.dataset.issueId + '"]');
  }

  function commaSeparatedValues(value) {
    return (value || '').split(',').filter(function(entry) { return entry.length > 0; });
  }

  function canDropOn(zone, draggedNode) {
    if (!draggedNode) return false;
    if (draggedNode.dataset.reorderable !== 'true') return false;
    if (!zone) return false;
    var targetNode = zone.closest('.cosmosys-dnd-item');
    if (targetNode && targetNode.dataset.issueId === draggedNode.dataset.issueId) return false;
    if (targetNode && isDescendant(targetNode, draggedNode)) return false;

    var parentIssueId = zone.dataset.dropParentId || '';
    if (parentIssueId.length === 0) {
      if ((zone.dataset.moveMode === 'before' || zone.dataset.moveMode === 'after') &&
          zone.dataset.dropParentProjectId !== draggedNode.dataset.projectId) return false;
      return true;
    }

    if (zone.dataset.dropParentCanHaveChildren !== 'true') return false;
    var allowedProfiles = commaSeparatedValues(draggedNode.dataset.allowedParentProfiles);
    if (allowedProfiles.length > 0 && allowedProfiles.indexOf(zone.dataset.dropParentProfile) === -1) return false;

    var allowedProjectIds = commaSeparatedValues(draggedNode.dataset.projectAncestors);
    if (allowedProjectIds.indexOf(zone.dataset.dropParentProjectId) === -1) return false;
    return true;
  }

  function submitMove(issueId, parentIssueId, moveMode, targetIssueId) {
    var form = document.getElementById('cosmosys-tree-form');
    if (!form) return;
    document.getElementById('cosmosys-tree-issue-id').value = issueId;
    document.getElementById('cosmosys-tree-parent-id').value = parentIssueId || '';
    document.getElementById('cosmosys-tree-target-id').value = targetIssueId || '';
    document.getElementById('cosmosys-tree-move-mode').value = moveMode || 'child';
    form.submit();
  }

  function refreshDropCandidates(draggedNode) {
    document.querySelectorAll('.cosmosys-dnd-dropzone').forEach(function(zone) {
      var allowed = canDropOn(zone, draggedNode);
      zone.classList.toggle('cosmosys-drop-candidate', allowed);
    });
  }

  function clearDropState() {
    document.querySelectorAll('.cosmosys-drop-candidate, .cosmosys-drop-allowed, .cosmosys-drop-denied').forEach(function(node) {
      node.classList.remove('cosmosys-drop-candidate', 'cosmosys-drop-allowed', 'cosmosys-drop-denied');
    });
  }

  function createDragGhost(item) {
    var node = item.querySelector('.cosmosys-dnd-node');
    if (!node) return null;

    var ghost = document.createElement('div');
    ghost.className = 'cosmosys-drag-ghost';
    ghost.textContent = node.innerText.replace(/\s+/g, ' ').trim();
    document.body.appendChild(ghost);
    return ghost;
  }

  function initDragAndDrop() {
    var draggedNode = null;
    var treeView = document.querySelector('.cosmosys-tree-reorder-view');

    document.querySelectorAll('.cosmosys-dnd-item[draggable="true"]').forEach(function(item) {
      if (item.dataset.cosmosysDndBound === '1') return;
      item.dataset.cosmosysDndBound = '1';

      item.addEventListener('dragstart', function(event) {
        event.stopPropagation();
        draggedNode = item;
        item.classList.add('cosmosys-dragging');
        if (treeView) treeView.classList.add('cosmosys-drag-active');
        refreshDropCandidates(draggedNode);
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', item.dataset.issueId);

        var ghost = createDragGhost(item);
        if (ghost) {
          event.dataTransfer.setDragImage(ghost, 12, 12);
          setTimeout(function() { ghost.remove(); }, 0);
        }
      });

      item.addEventListener('dragend', function(event) {
        event.stopPropagation();
        item.classList.remove('cosmosys-dragging');
        if (treeView) treeView.classList.remove('cosmosys-drag-active');
        clearDropState();
        draggedNode = null;
      });
    });

    document.querySelectorAll('.cosmosys-dnd-dropzone').forEach(function(zone) {
      if (zone.dataset.cosmosysDndBound === '1') return;
      zone.dataset.cosmosysDndBound = '1';

      zone.addEventListener('dragover', function(event) {
        var allowed = canDropOn(zone, draggedNode);
        zone.classList.toggle('cosmosys-drop-allowed', allowed);
        zone.classList.toggle('cosmosys-drop-denied', !allowed && !!draggedNode);
        if (allowed) {
          event.preventDefault();
          event.dataTransfer.dropEffect = 'move';
        }
      });

      zone.addEventListener('dragleave', function() {
        zone.classList.remove('cosmosys-drop-allowed', 'cosmosys-drop-denied');
      });

      zone.addEventListener('drop', function(event) {
        var moveMode = zone.dataset.moveMode || 'child';
        event.preventDefault();
        event.stopPropagation();
        if (!canDropOn(zone, draggedNode)) return;
        submitMove(
          draggedNode.dataset.issueId,
          zone.dataset.dropParentId,
          moveMode,
          zone.dataset.targetIssueId
        );
      });
    });
  }

  function updateSidebarSelection(item) {
    var sidebar = document.querySelector('[data-cosmosys-tree-sidebar]');
    if (!sidebar || !item) return;

    var body = sidebar.querySelector('[data-cosmosys-tree-sidebar-body]');
    var issueUrl = item.dataset.issueSidebarUrl;

    document.querySelectorAll('.cosmosys-tree-item.cosmosys-selected').forEach(function(node) {
      node.classList.remove('cosmosys-selected');
    });
    item.classList.add('cosmosys-selected');

    if (!body || !issueUrl) return;

    body.dataset.loading = '1';
    window.fetch(issueUrl, { headers: { 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function(response) { return response.text(); })
      .then(function(html) {
        if (!item.classList.contains('cosmosys-selected')) return;
        body.innerHTML = html;
      })
      .catch(function() {
        if (!item.classList.contains('cosmosys-selected')) return;
        body.innerHTML = '<p class="nodata">Unable to load item details.</p>';
      })
      .finally(function() {
        delete body.dataset.loading;
      });
  }

  function initTreeSidebar() {
    var sidebar = document.querySelector('[data-cosmosys-tree-sidebar]');
    if (!sidebar) return;

    var selected = document.querySelector('.cosmosys-tree-item[data-issue-id]');
    if (selected) updateSidebarSelection(selected);

    document.querySelectorAll('.cosmosys-tree-node').forEach(function(node) {
      if (node.dataset.cosmosysSidebarBound === '1') return;
      node.dataset.cosmosysSidebarBound = '1';

      node.addEventListener('click', function(event) {
        if (event.target.closest('a, button, .cosmosys-tree-drag-handle')) return;
        if (document.querySelector('.cosmosys-tree-reorder-view.cosmosys-drag-active')) return;

        var item = node.closest('.cosmosys-tree-item');
        if (!item) return;
        updateSidebarSelection(item);
      });
    });
  }

  function initReportSearch() {
    var reportToc = document.querySelector('[data-cosmosys-report-toc]');
    var searchInput = document.querySelector('[data-cosmosys-report-search]');
    if (!reportToc || !searchInput || searchInput.dataset.cosmosysBound === '1') return;

    searchInput.dataset.cosmosysBound = '1';
    searchInput.addEventListener('input', function() {
      var query = searchInput.value.toLowerCase().trim();

      reportToc.querySelectorAll('[data-cosmosys-report-item]').forEach(function(node) {
        var haystack = (node.dataset.cosmosysReportText || '').toLowerCase();
        var visible = query === '' || haystack.indexOf(query) !== -1;
        node.hidden = !visible;
      });
    });
  }

  function initReportTocNavigation() {
    var reportView = document.querySelector('[data-cosmosys-report]');
    var scrollbox = document.querySelector('[data-cosmosys-report-scrollbox]');
    var toc = document.querySelector('[data-cosmosys-report-toc]');
    if (!reportView || !scrollbox || !toc || toc.dataset.cosmosysBound === '1') return;

    toc.dataset.cosmosysBound = '1';
    toc.addEventListener('click', function(event) {
      var link = event.target.closest('a[href^="#"]');
      if (!link) return;

      var anchor = link.getAttribute('href');
      if (!anchor || anchor === '#') return;

      var target = reportView.querySelector(anchor);
      if (!target) return;

      event.preventDefault();

      var top = target.offsetTop - 12;
      scrollbox.scrollTo({ top: top, behavior: 'smooth' });

      if (window.history && window.history.replaceState) {
        window.history.replaceState(null, '', anchor);
      } else {
        window.location.hash = anchor;
      }
    });
  }

  function syncReportFieldPresentationRows(container) {
    if (!container) return;

    var sourceId = container.getAttribute('data-selected-source-id');
    var selected = sourceId ? document.getElementById(sourceId) : null;
    if (!selected) return;

    var selectedNames = Array.prototype.map.call(selected.options, function(option) { return option.value; });
    Array.prototype.forEach.call(container.querySelectorAll('tr[data-column-name]'), function(row) {
      row.hidden = selectedNames.indexOf(row.getAttribute('data-column-name')) === -1;
    });
  }

  function initReportFieldPresentations() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-cosmosys-report-field-presentations]'), syncReportFieldPresentationRows);

    if (document.body.dataset.cosmosysReportFieldPresentationBound === '1') return;
    document.body.dataset.cosmosysReportFieldPresentationBound = '1';

    document.addEventListener('click', function(event) {
      if (event.target && event.target.tagName === 'INPUT' && event.target.type === 'button') {
        window.setTimeout(function() {
          Array.prototype.forEach.call(document.querySelectorAll('[data-cosmosys-report-field-presentations]'), syncReportFieldPresentationRows);
        }, 0);
      }
    });

    document.addEventListener('dblclick', function() {
      window.setTimeout(function() {
        Array.prototype.forEach.call(document.querySelectorAll('[data-cosmosys-report-field-presentations]'), syncReportFieldPresentationRows);
      }, 0);
    });
  }

  function initCombinedDiagramControls() {
    if (document.body.dataset.cosmosysCombinedDiagramBound === '1') return;
    document.body.dataset.cosmosysCombinedDiagramBound = '1';

    document.addEventListener('submit', function(event) {
      var form = event.target.closest('[data-cosmosys-diagram-options]');
      if (!form) return;
      event.preventDefault();
      var panel = form.closest('[data-cosmosys-diagram-panel]');
      if (!panel || panel.dataset.loading === '1') return;
      var panelUrl = panel.getAttribute('data-panel-url');
      if (!panelUrl) return;
      reloadDiagramPanel(panel, panelUrl, diagramPanelParams(panel));
    });
  }

  var diagramRequestControllers = [];
  var diagramPageLeaving = false;

  function trackDiagramRequestController(controller) {
    diagramRequestControllers.push(controller);
    return controller;
  }

  function releaseDiagramRequestController(controller) {
    var index = diagramRequestControllers.indexOf(controller);
    if (index !== -1) diagramRequestControllers.splice(index, 1);
  }

  function abortDeferredDiagramRequests() {
    diagramPageLeaving = true;
    diagramRequestControllers.splice(0).forEach(function(controller) { controller.abort(); });
    reportDiagramQueue.splice(0).forEach(function(job) {
      job.reject(new DOMException('Page is leaving', 'AbortError'));
    });
  }

  function initLazyPageDiagrams() {
    var nodes = Array.prototype.slice.call(document.querySelectorAll('[data-cosmosys-page-diagram]'));
    if (!nodes.length) return;

    var total = nodes.length;
    var complete = 0;
    var active = 0;
    var maximumParallelLoads = 2;
    var progress = document.createElement('div');
    progress.className = 'cosmosys-page-diagram-progress';
    progress.setAttribute('role', 'status');
    progress.setAttribute('aria-live', 'polite');
    progress.innerHTML = '<span class="cosmosys-spinner" aria-hidden="true"></span>' +
      '<span data-cosmosys-page-diagram-progress-text></span>' +
      '<progress max="' + total + '" value="0"></progress>';
    document.body.appendChild(progress);

    function refreshProgress() {
      var template = nodes[0].dataset.progressText || 'Loading diagrams: __LOADED__/__TOTAL__';
      progress.querySelector('[data-cosmosys-page-diagram-progress-text]').textContent = template
        .replace('__LOADED__', complete)
        .replace('__TOTAL__', total);
      progress.querySelector('progress').value = complete;
      if (complete === total) {
        progress.classList.add('cosmosys-page-diagram-progress-complete');
        window.setTimeout(function() { progress.remove(); }, 900);
      }
    }

    function load(node) {
      active += 1;
      var controller = trackDiagramRequestController(new AbortController());
      window.fetch(node.dataset.url, {
        credentials: 'same-origin',
        headers: { 'X-Requested-With': 'XMLHttpRequest' },
        signal: controller.signal
      })
        .then(function(response) {
          if (!response.ok) throw new Error('Diagram request failed');
          return response.text();
        })
        .then(function(html) { node.outerHTML = html; })
        .catch(function(error) {
          if (error.name === 'AbortError') return;
          node.classList.remove('cosmosys-lazy-diagram');
          node.innerHTML = '<p class="nodata"></p>';
          node.querySelector('p').textContent = node.dataset.errorText || 'Diagram unavailable';
        })
        .finally(function() {
          releaseDiagramRequestController(controller);
          active -= 1;
          complete += 1;
          if (diagramPageLeaving) return;
          refreshProgress();
          pump();
        });
    }

    function pump() {
      while (active < maximumParallelLoads && nodes.length > complete + active) {
        load(nodes[complete + active]);
      }
    }

    refreshProgress();
    pump();
  }

  function diagramPanelParams(panel) {
    var params = new URLSearchParams();
    params.set('visible_layers_present', '1');
    panel.querySelectorAll('input[name="visible_layers[]"]:checked').forEach(function(input) {
      params.append('visible_layers[]', input.value);
    });
    var variantSelect = panel.querySelector('[data-cosmosys-combined-control="render_variant"]');
    var layoutSelect = panel.querySelector('[data-cosmosys-combined-control="combined_layout_mode"]');
    if (variantSelect) params.set('render_variant', variantSelect.value);
    if (layoutSelect) params.set('combined_layout_mode', layoutSelect.value);
    return params;
  }

  function reloadDiagramPanel(panel, panelUrl, params) {
      panel.dataset.loading = '1';
      panel.classList.add('cosmosys-diagram-panel-loading');

      var requestUrl = new URL(panelUrl, window.location.href);
      params.forEach(function(value, key) {
        requestUrl.searchParams.append(key, value);
      });

      window.fetch(requestUrl.toString(), {
        headers: { 'X-Requested-With': 'XMLHttpRequest' }
      })
        .then(function(response) {
          if (!response.ok) throw new Error('Request failed');
          return response.text();
        })
        .then(function(html) {
          panel.outerHTML = html;
        })
        .catch(function() {
          panel.classList.remove('cosmosys-diagram-panel-loading');
        })
        .finally(function() {
          delete panel.dataset.loading;
        });
  }

  var reportDiagramQueue = [];
  var activeReportDiagramLoads = 0;
  var maxReportDiagramLoads = 3;

  function pumpReportDiagramQueue() {
    while (!diagramPageLeaving && activeReportDiagramLoads < maxReportDiagramLoads && reportDiagramQueue.length) {
      let job = reportDiagramQueue.shift();
      activeReportDiagramLoads += 1;
      let controller = trackDiagramRequestController(new AbortController());
      window.fetch(job.node.dataset.url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' }, signal: controller.signal })
        .then(function(response) {
          if (!response.ok) throw new Error('Diagram request failed');
          return response.text();
        })
        .then(function(html) {
          job.node.innerHTML = html;
          job.node.dataset.loaded = '1';
          job.resolve(job.node);
        })
        .catch(function(error) {
          job.node.dataset.failed = '1';
          job.reject(error);
        })
        .finally(function() {
          releaseDiagramRequestController(controller);
          activeReportDiagramLoads -= 1;
          pumpReportDiagramQueue();
        });
    }
  }

  function loadReportDiagram(node) {
    if (diagramPageLeaving) return Promise.reject(new DOMException('Page is leaving', 'AbortError'));
    if (node.dataset.loaded === '1') return Promise.resolve(node);
    if (node._cosmosysLoadPromise) return node._cosmosysLoadPromise;
    node._cosmosysLoadPromise = new Promise(function(resolve, reject) {
      reportDiagramQueue.push({ node: node, resolve: resolve, reject: reject });
      pumpReportDiagramQueue();
    });
    return node._cosmosysLoadPromise;
  }

  function initLazyReportDiagrams() {
    var report = document.querySelector('[data-cosmosys-report]');
    var nodes = Array.prototype.slice.call(document.querySelectorAll('[data-cosmosys-report-diagram]'));
    var exportButtons = Array.prototype.slice.call(document.querySelectorAll('[data-cosmosys-report-export]'));
    if (!report) return;
    if (!nodes.length) {
      exportButtons.forEach(function(button) { button.disabled = false; });
      return;
    }

    var total = nodes.length, settled = 0, failed = 0;
    var progress = document.createElement('div');
    progress.className = 'cosmosys-page-diagram-progress cosmosys-report-diagram-progress';
    progress.setAttribute('role', 'status');
    progress.setAttribute('aria-live', 'polite');
    progress.innerHTML = '<span class="cosmosys-spinner" aria-hidden="true"></span>' +
      '<span data-cosmosys-report-diagram-progress-text></span>' +
      '<progress max="' + total + '" value="0"></progress>';
    document.body.appendChild(progress);

    function interpolate(template, values) {
      return Object.keys(values).reduce(function(result, key) {
        return result.replace('__' + key.toUpperCase() + '__', values[key]);
      }, template);
    }

    function updateProgress() {
      var text;
      if (settled < total) {
        text = interpolate(report.dataset.diagramProgressText, { loaded: settled, total: total });
      } else if (failed) {
        text = interpolate(report.dataset.diagramFailedText, { failed: failed, total: total });
        progress.classList.add('cosmosys-report-diagram-progress-failed');
      } else {
        text = interpolate(report.dataset.diagramReadyText, { total: total });
        progress.classList.add('cosmosys-page-diagram-progress-complete');
        exportButtons.forEach(function(button) { button.disabled = false; });
        window.setTimeout(function() { progress.remove(); }, 1800);
      }
      progress.querySelector('[data-cosmosys-report-diagram-progress-text]').textContent = text;
      progress.querySelector('progress').value = settled;
    }

    updateProgress();
    nodes.forEach(function(node) {
      loadReportDiagram(node)
        .catch(function() {
          failed += 1;
          node.innerHTML = '<p class="nodata"></p>';
          node.querySelector('p').textContent = report.dataset.diagramErrorText;
        })
        .finally(function() {
          settled += 1;
          updateProgress();
        });
    });
  }

  function downloadReportBlob(blob, title, format) {
    var url = URL.createObjectURL(blob);
    var link = document.createElement('a');
    link.href = url;
    link.download = title.replace(/[^0-9A-Za-z._-]+/g, '_') + '.' + format;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
  }

  function downloadNamedBlob(blob, filename) {
    var url = URL.createObjectURL(blob);
    var link = document.createElement('a');
    link.href = url;
    link.download = filename.replace(/[^0-9A-Za-z._-]+/g, '_');
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
  }

  function responseFilename(response, fallback) {
    var disposition = response.headers.get('Content-Disposition') || '';
    var utf8Match = disposition.match(/filename\*=UTF-8''([^;]+)/i);
    if (utf8Match) return decodeURIComponent(utf8Match[1].replace(/^"|"$/g, ''));
    var plainMatch = disposition.match(/filename="?([^";]+)"?/i);
    return plainMatch ? plainMatch[1] : fallback;
  }

  function refreshOdsTransferHistory() {
    var currentTable = document.querySelector('[data-cosmosys-ods-transfer-history]');
    if (!currentTable) return Promise.resolve();

    return window.fetch(window.location.href, {
      method: 'GET',
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'XMLHttpRequest' }
    })
      .then(function(response) {
        if (!response.ok) throw new Error('ODS transfer history refresh failed');
        return response.text();
      })
      .then(function(html) {
        var parsed = new DOMParser().parseFromString(html, 'text/html');
        var updatedTable = parsed.querySelector('[data-cosmosys-ods-transfer-history]');
        if (!updatedTable) throw new Error('ODS transfer history table is missing');
        currentTable.replaceWith(updatedTable);
      });
  }

  function initReportExport() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-cosmosys-report-export]'), function(button) {
      if (button.dataset.cosmosysBound === '1') return;
      button.dataset.cosmosysBound = '1';
      button.addEventListener('click', function() {
        var toolbar = button.closest('.cosmosys-ods-export-toolbar, .cosmosys-report-export-toolbar');
        var formatControl = toolbar.querySelector('[data-cosmosys-report-export-format]');
        var progress = toolbar.querySelector('[data-cosmosys-report-export-progress]');
        var format = formatControl.value;
        var token = document.querySelector('meta[name="csrf-token"]');

        button.disabled = true;
        formatControl.disabled = true;
        progress.hidden = false;

        var body = new FormData();
        body.append('format', format);
        window.fetch(button.dataset.exportUrl, {
          method: 'POST',
          body: body,
          credentials: 'same-origin',
          headers: token ? { 'X-CSRF-Token': token.content, 'X-Requested-With': 'XMLHttpRequest' } : {}
        })
          .then(function(response) {
            if (!response.ok) throw new Error('Report export failed');
            return response.blob();
          })
          .then(function(blob) {
            downloadReportBlob(blob, button.dataset.exportTitle || 'cosmosys-report', format);
          })
          .catch(function(error) {
            window.alert(button.dataset.exportError || error.message);
          })
          .finally(function() {
            button.disabled = false;
            formatControl.disabled = false;
            progress.hidden = true;
          });
      });
    });
  }

  function initOdsExport() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-cosmosys-ods-export]'), function(button) {
      if (button.dataset.cosmosysBound === '1') return;
      button.dataset.cosmosysBound = '1';
      button.addEventListener('click', function() {
        var toolbar = button.closest('.cosmosys-report-export-toolbar');
        var progress = toolbar.querySelector('[data-cosmosys-ods-export-progress]');
        var progressBar = progress.querySelector('[data-cosmosys-operation-progress]');
        var progressLabel = progress.querySelector('[data-cosmosys-operation-label]');
        var progressSpinner = progress.querySelector('[data-cosmosys-operation-spinner]');
        var token = document.querySelector('meta[name="csrf-token"]');
        var exportButtons = toolbar.querySelectorAll('[data-cosmosys-ods-export]');
        var writerSelect = toolbar.querySelector('[data-cosmosys-ods-export-writer]');
        var exportUrl = new URL(button.dataset.exportUrl, window.location.href);
        exportUrl.searchParams.set('writer', writerSelect.value);
        var completed = false;

        exportButtons.forEach(function(candidate) { candidate.disabled = true; });
        writerSelect.disabled = true;
        progressBar.value = 0;
        progressSpinner.hidden = false;
        progress.hidden = false;
        window.fetch(exportUrl.toString(), {
          method: 'POST',
          credentials: 'same-origin',
          headers: token ? { 'X-CSRF-Token': token.content, 'X-Requested-With': 'XMLHttpRequest' } : {}
        })
          .then(function(response) {
            if (!response.ok) throw new Error('ODS export failed');
            return response.json();
          })
          .then(function(operation) {
            return pollCosmosysOperation(operation.status_url, function(status) {
              progressBar.value = status.progress || 0;
              progressBar.textContent = (status.progress || 0) + '%';
              progressLabel.textContent = status.phase_label || status.phase;
            });
          })
          .then(function(status) {
            completed = true;
            progressBar.value = 100;
            progressBar.textContent = '100%';
            progressLabel.textContent = status.completion_label || status.phase_label || status.phase;
            progressSpinner.hidden = true;
            return window.fetch(status.download_url, { credentials: 'same-origin' }).then(function(response) {
              if (!response.ok) throw new Error('ODS download failed');
              var filename = responseFilename(response, status.filename || (button.dataset.exportTitle || 'cosmosys-items') + '.ods');
              return response.blob().then(function(blob) { return { blob: blob, filename: filename }; });
            });
          })
          .then(function(download) {
            downloadNamedBlob(download.blob, download.filename);
            return refreshOdsTransferHistory().catch(function() {
              window.location.reload();
            });
          })
          .catch(function(error) {
            window.alert(button.dataset.exportError || error.message);
          })
          .finally(function() {
            exportButtons.forEach(function(candidate) { candidate.disabled = false; });
            writerSelect.disabled = false;
            progress.hidden = completed ? false : true;
          });
      });
    });
  }

  function pollCosmosysOperation(statusUrl, onProgress) {
    return window.fetch(statusUrl, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function(response) {
        if (!response.ok) throw new Error('Background operation status failed');
        return response.json();
      })
      .then(function(status) {
        onProgress(status);
        if (status.state === 'applied') return status;
        if (['failed', 'rejected'].indexOf(status.state) >= 0) throw new Error(status.phase_label || 'Background operation failed');
        return new Promise(function(resolve) { window.setTimeout(resolve, 750); })
          .then(function() { return pollCosmosysOperation(statusUrl, onProgress); });
      });
  }

  function relocateProjectDiagrams() {
    document.querySelectorAll('[data-cosmosys-project-diagrams]').forEach(function(diagrams) {
      var splitContent = diagrams.closest('.splitcontent');
      if (!splitContent || splitContent.nextElementSibling === diagrams) return;

      splitContent.insertAdjacentElement('afterend', diagrams);
    });
  }

  function initOdsImportForms() {
    document.querySelectorAll('[data-cosmosys-ods-import-form]').forEach(function(form) {
      if (form.dataset.cosmosysBound === '1') return;
      form.dataset.cosmosysBound = '1';
      form.addEventListener('submit', function() {
        var progress = form.querySelector('[data-cosmosys-ods-import-progress]');
        var submit = form.querySelector('[data-cosmosys-ods-import-submit], input[type="submit"], button[type="submit"]');
        if (progress) progress.hidden = false;
        if (submit) submit.disabled = true;
      });
    });
  }

  function initDsm() {
    var frame = document.querySelector('[data-cosmosys-dsm]');
    var source = document.getElementById('cosmosys-dsm-data');
    if (!frame || !source || frame.dataset.cosmosysBound === '1') return;
    frame.dataset.cosmosysBound = '1';

    var payload = JSON.parse(source.textContent);
    var itemsById = {};
    payload.items.forEach(function(item) { itemsById[item.id] = item; });
    var fullOrder = payload.items.map(function(item) { return item.id; });
    var connectedIds = {};
    payload.compact_item_ids.forEach(function(id) { connectedIds[id] = true; });
    var compact = true;
    var order = fullOrder.filter(function(id) { return connectedIds[id]; });
    var cells = {};
    payload.cells.forEach(function(cell) { cells[cell.dependent_id + ':' + cell.prerequisite_id] = cell; });
    var draggedId = null;
    var toggle = document.querySelector('[data-cosmosys-dsm-toggle]');

    function overlap(left, right) {
      return left.some(function(value) { return right.indexOf(value) !== -1; });
    }

    function cellTitle(cell) {
      return cell.sources.map(function(sourceItem) {
        var projection = sourceItem.ghost ? ' [' + payload.labels.projection + ']' : '';
        return sourceItem.from + ' ' + sourceItem.type + ' ' + sourceItem.to + projection;
      }).join('\n');
    }

    function feedbackGroupCount() {
      var adjacency = {};
      order.forEach(function(id) { adjacency[id] = []; });
      payload.cells.forEach(function(cell) { adjacency[cell.prerequisite_id].push(cell.dependent_id); });
      var index = 0, indices = {}, low = {}, stack = [], stacked = {}, groups = 0;
      function visit(id) {
        indices[id] = index; low[id] = index; index += 1; stack.push(id); stacked[id] = true;
        adjacency[id].forEach(function(next) {
          if (indices[next] === undefined) { visit(next); low[id] = Math.min(low[id], low[next]); }
          else if (stacked[next]) low[id] = Math.min(low[id], indices[next]);
        });
        if (low[id] !== indices[id]) return;
        var size = 0, member;
        do { member = stack.pop(); stacked[member] = false; size += 1; } while (member !== id);
        if (size > 1) groups += 1;
      }
      order.forEach(function(id) { if (indices[id] === undefined) visit(id); });
      return groups;
    }

    function renderDiagnostics() {
      var positions = {};
      order.forEach(function(id, index) { positions[id] = index; });
      var restricted = 0, planning = 0, distance = 0;
      payload.cells.forEach(function(cell) {
        var delta = positions[cell.prerequisite_id] - positions[cell.dependent_id];
        if (delta <= 0) return;
        if (cell.restricted) restricted += 1;
        if (cell.planning) planning += 1;
        distance = Math.max(distance, delta);
      });
      var labels = payload.labels;
      document.querySelector('[data-cosmosys-dsm-diagnostics]').textContent =
        labels.backward + ': ' + restricted + ' ' + labels.restricted + ', ' + planning + ' ' + labels.planning +
        ' · ' + labels.feedback + ': ' + feedbackGroupCount() + ' · ' + labels.distance + ': ' + distance;
    }

    function highlightGroup(item, active) {
      if (!item.group_ids.length) return;
      payload.items.forEach(function(candidate) {
        if (!overlap(item.group_ids, candidate.group_ids)) return;
        var row = frame.querySelector('tbody > tr[data-dsm-item-id="' + candidate.id + '"]');
        if (!row) return;
        [row.children[0], row.children[1]].forEach(function(node) {
          if (node) node.classList.toggle('cosmosys-dsm-group-highlight', active);
        });
      });
    }

    function render() {
      frame.innerHTML = '';
      if (toggle) toggle.textContent = compact ? payload.labels.expand : payload.labels.compact;
      if (!order.length) { frame.textContent = payload.labels.empty; return; }
      var table = document.createElement('table');
      table.className = 'list cosmosys-dsm-table';
      var head = document.createElement('thead'), headRow = document.createElement('tr');
      [payload.labels.sequence, payload.labels.item].forEach(function(label) {
        var th = document.createElement('th'); th.textContent = label; headRow.appendChild(th);
      });
      order.forEach(function(id, index) {
        var item = itemsById[id], th = document.createElement('th');
        th.className = 'cosmosys-dsm-column-header'; th.dataset.dsmItemId = id;
        th.title = item.csid + ' — ' + item.subject; th.textContent = index + 1; headRow.appendChild(th);
      });
      head.appendChild(headRow); table.appendChild(head);

      var body = document.createElement('tbody');
      order.forEach(function(rowId, rowIndex) {
        var item = itemsById[rowId], row = document.createElement('tr');
        row.draggable = true; row.dataset.dsmItemId = rowId;
        var sequence = document.createElement('td'); sequence.className = 'cosmosys-dsm-sequence'; sequence.textContent = rowIndex + 1; row.appendChild(sequence);
        var label = document.createElement('td'); label.className = 'cosmosys-dsm-item-label';
        var link = document.createElement('a'); link.href = item.url; link.textContent = item.tracker + ':' + item.csid + ' ' + item.subject; label.appendChild(link);
        if (item.hierarchy_path.length) { var path = document.createElement('small'); path.textContent = item.hierarchy_path.join(' › '); label.appendChild(path); }
        row.appendChild(label);
        order.forEach(function(columnId, columnIndex) {
          var td = document.createElement('td'); td.className = 'cosmosys-dsm-cell'; td.dataset.dsmItemId = columnId;
          if (rowId === columnId) { td.classList.add('cosmosys-dsm-diagonal'); td.textContent = rowIndex + 1; }
          else {
            var cell = cells[rowId + ':' + columnId];
            if (cell) {
              td.textContent = cell.relation_types.indexOf('blocks') !== -1 ? 'X' : '←';
              td.classList.add(cell.restricted ? 'cosmosys-dsm-restricted' : 'cosmosys-dsm-planning');
              if (cell.restricted && cell.planning) td.classList.add('cosmosys-dsm-mixed');
              if (cell.ghost) td.classList.add('cosmosys-dsm-ghost');
              if (columnIndex > rowIndex) td.classList.add('cosmosys-dsm-backward');
              td.title = cellTitle(cell);
            }
          }
          row.appendChild(td);
        });
        row.addEventListener('mouseenter', function() { highlightGroup(item, true); });
        row.addEventListener('mouseleave', function() { highlightGroup(item, false); });
        row.addEventListener('dragstart', function() { draggedId = rowId; row.classList.add('cosmosys-dsm-dragging'); });
        row.addEventListener('dragend', function() { draggedId = null; row.classList.remove('cosmosys-dsm-dragging'); });
        row.addEventListener('dragover', function(event) { if (draggedId && draggedId !== rowId) event.preventDefault(); });
        row.addEventListener('drop', function(event) {
          event.preventDefault(); if (!draggedId || draggedId === rowId) return;
          function moveBefore(list, movingId, targetId) {
            var moving = list.indexOf(movingId), target = list.indexOf(targetId);
            if (moving < 0 || target < 0) return;
            var value = list.splice(moving, 1)[0];
            if (moving < target) target -= 1;
            list.splice(target, 0, value);
          }
          moveBefore(order, draggedId, rowId);
          moveBefore(fullOrder, draggedId, rowId);
          render();
        });
        body.appendChild(row);
      });
      table.appendChild(body);
      table.addEventListener('mouseover', function(event) {
        var cell = event.target.closest('.cosmosys-dsm-cell');
        if (!cell || !table.contains(cell)) return;
        var column = cell.cellIndex + 1;
        table.querySelectorAll('tr > :nth-child(' + column + ')').forEach(function(node) {
          node.classList.add('cosmosys-dsm-column-highlight');
        });
      });
      table.addEventListener('mouseout', function(event) {
        var cell = event.target.closest('.cosmosys-dsm-cell');
        if (!cell || !table.contains(cell)) return;
        var nextCell = event.relatedTarget && event.relatedTarget.closest && event.relatedTarget.closest('.cosmosys-dsm-cell');
        if (nextCell === cell) return;
        table.querySelectorAll('.cosmosys-dsm-column-highlight').forEach(function(node) {
          node.classList.remove('cosmosys-dsm-column-highlight');
        });
      });
      frame.appendChild(table); renderDiagnostics();
    }
    if (toggle) toggle.addEventListener('click', function() {
      compact = !compact;
      order = compact ? fullOrder.filter(function(id) { return connectedIds[id]; }) : fullOrder.slice();
      render();
    });
    render();
  }

  window.addEventListener('beforeunload', abortDeferredDiagramRequests);
  window.addEventListener('pagehide', abortDeferredDiagramRequests);

  document.addEventListener('DOMContentLoaded', function() {
    initDocumentReferenceSearch();
    relocateProjectDiagrams();
    restoreCollapsedState();
    initTreeToggles();
    initTreeToolbar();
    initDragAndDrop();
    initTreeSidebar();
    initReportSearch();
    initReportTocNavigation();
    initReportFieldPresentations();
    initLazyReportDiagrams();
    initReportExport();
    initOdsExport();
    initOdsImportForms();
    initDsm();
    initCombinedDiagramControls();
    initLazyPageDiagrams();
  });
})();
