(() => {
  'use strict';
  const folder = 'UAgent-wallets';
  const archiveName = 'wallets.json';
  const format = 'uagent-wallet-backup-v2';
  const lock = 'uagent-wallet-backup-files-v1';
  const permission = {mode: 'readwrite'};
  const selectionKey = 'uagent.wallet-directory.selection';
  const purposeLabels = new Map(Object.entries({
    'trade-group': '批量交易组',
    'linked-seller': '关联交易卖方',
    'linked-buyer': '关联交易买方',
    'linked-transit': '关联交易中转',
    'tool-generated': '工具生成钱包',
    'distribution-transit': '分发中转',
    'tool-distribution-source': '分发来源',
    'tool-collection-source': '归集来源',
    'launch-dev': '发币开发者',
    'launch-internal-buyer': '发币内盘买方',
    'launch-external-buyer': '发币外盘买方',
  }));
  const addressPattern = /^0x[0-9a-f]{40}$/i;
  const keyPattern = /^(?:0x)?[0-9a-f]{64}$/i;
  let selected;
  let choosing = false;
  let operations = 0;
  let selectionVersion = 0;

  class BackupError extends Error {}
  class PermissionError extends BackupError {}
  function supported() {
    return globalThis.isSecureContext && typeof showDirectoryPicker === 'function' &&
      typeof navigator.locks?.request === 'function';
  }

  function randomToken() {
    if (crypto.randomUUID) return crypto.randomUUID();
    return Array.from(crypto.getRandomValues(new Uint8Array(16)),
      byte => byte.toString(16).padStart(2, '0')).join('');
  }

  // IndexedDB contains exactly one directory handle. All wallet data lives in the picked folder.
  async function withHandleStore(mode, request) {
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open('uagent-wallet-directory-v1', 1);
      req.onupgradeneeded = () => req.result.createObjectStore('selection');
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction('selection', mode);
        const req = request(tx.objectStore('selection'));
        tx.oncomplete = () => resolve(req.result);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  }

  async function rememberSelection(handle) {
    // Rotate the tab's public selection token BEFORE touching IndexedDB. If the
    // database is blocked or full, a reload cannot resolve the old handle.
    const token = randomToken();
    try {
      sessionStorage.setItem(selectionKey, token);
    } catch {
      // The file grant still works when all browser storage is disabled.
      // Also suppress any stale tab token if storage becomes readable again.
      history.replaceState({...history.state, [selectionKey]: 'reselect'}, '');
      return;
    }
    try {
      await navigator.locks.request(lock + '-selection', async () => {
        const previous = await withHandleStore('readonly', store => store.openCursor());
        if (previous && previous.key !== 'directory' && await previous.value.isSameEntry(handle)) {
          // Other tabs explicitly selecting the same directory can share its handle.
          sessionStorage.setItem(selectionKey, previous.key);
        } else {
          await withHandleStore('readwrite', store => {
            store.clear();
            return store.put(handle, token);
          });
        }
      });
      if (history.state?.[selectionKey]) {
        const state = {...history.state};
        delete state[selectionKey];
        history.replaceState(state, '');
      }
    } catch {
      // Persistence is optional. Files still go to the handle the user just granted.
    }
  }

  // Exercise the same local filesystem as a backup, including commit and readback.
  // Use a fresh public marker only during connection, never during polling.
  async function verifyWritable(handle) {
    await navigator.locks.request(lock, async () => {
      const base = await handle.getDirectoryHandle(folder, {create: true});
      const token = randomToken();
      const name = 'uagent-write-check-' + token + '.txt';
      if (await optionalEntry(() => base.getFileHandle(name))) {
        throw new BackupError('无法验证目录写入，请重新连接文件夹');
      }
      const file = await base.getFileHandle(name, {create: true});
      let output;
      let verified = false;
      try {
        output = await file.createWritable({mode: 'exclusive'});
        if ((await file.getFile()).size !== 0) {
          throw new BackupError('目录验证文件被占用，请重新连接文件夹');
        }
        await output.write(token);
        await output.close();
        output = null;
        const committed = await base.getFileHandle(name);
        const marker = await committed.getFile();
        if (!await file.isSameEntry(committed) || marker.size !== token.length || await marker.text() !== token) {
          throw new BackupError('目录写入校验失败，请检查所选文件夹');
        }
        verified = true;
      } finally {
        if (output) await output.abort().catch(() => {});
        try {
          const current = await optionalEntry(() => base.getFileHandle(name));
          if (current && await file.isSameEntry(current)) {
            const marker = await current.getFile();
            if (marker.size === 0 || (marker.size === token.length && await marker.text() === token)) {
              await base.removeEntry(name);
            } else if (verified) {
              throw new BackupError('目录验证文件已变更，请重新连接文件夹');
            }
          } else if (verified) {
            throw new BackupError('目录验证文件已变更，请重新连接文件夹');
          }
        } catch (cleanupError) {
          if (verified) throw cleanupError;
        }
      }
    });
  }

  async function checkAccess() {
    const handle = selected;
    if (!handle) return false;
    try {
      // queryPermission alone can stay granted after a folder is moved/deleted.
      if (await handle.queryPermission(permission) !== 'granted') {
        await withHistory(() => {}, handle);
        return false;
      }
      await handle.getDirectoryHandle(folder);
      await verifyHistory(handle);
      return true;
    } catch (error) {
      if (error?.name === 'NotAllowedError' || error?.name === 'SecurityError') return false;
      throw error;
    }
  }

  async function reconnect() {
    if (!supported() || choosing) return null;
    const version = selectionVersion;
    let handle;
    try {
      const token = sessionStorage.getItem(selectionKey);
      if (!token || history.state?.[selectionKey] === 'reselect') return null;
      handle = await withHandleStore('readonly', store => store.get(token));
    } catch {
      return null;
    }
    if (!handle || version !== selectionVersion) return null;
    if (await handle.queryPermission(permission) !== 'granted') {
      throw new PermissionError('备份目录授权已失效，请重新选择并授予读写权限');
    }
    await verifyWritable(handle);
    if (version !== selectionVersion) return null;
    await verifyHistory(handle);
    if (version !== selectionVersion) return null;
    selected = handle;
    return handle.name;
  }

  async function chooseDirectory() {
    if (!supported()) throw new BackupError('请使用支持目录写入的桌面浏览器，并通过 HTTPS 或本机地址打开');
    if (choosing || operations) throw new BackupError('请等待当前目录操作完成后再选择');
    choosing = true;
    selectionVersion++;
    try {
      let handle;
      try {
        // Call the picker before any await so the original click retains user activation.
        handle = await showDirectoryPicker({id: 'uagent-wallet-backup', mode: 'readwrite'});
      } catch (error) {
        if (error.name === 'AbortError') return null;
        throw error;
      }
      if (await handle.queryPermission(permission) !== 'granted' &&
          await handle.requestPermission(permission) !== 'granted') {
        throw new PermissionError('请授予所选目录读写权限');
      }
      await verifyWritable(handle);
      await verifyHistory(handle);
      selected = handle;
      // Even a storage-policy error while recording the tab marker must never
      // invalidate the live directory grant.
      await rememberSelection(handle).catch(() => {});
      return handle.name;
    } finally {
      choosing = false;
    }
  }

  async function withSelectedArchive(action, failureNotice) {
    const handle = selected;
    if (choosing || !handle) throw new BackupError('请先选择本机私钥备份目录');
    operations++;
    try {
      return await navigator.locks.request(lock, async () => {
        try {
          if (await handle.queryPermission(permission) !== 'granted') {
            throw new PermissionError('备份目录授权已失效，请重新选择并授予读写权限');
          }
          return await action(handle);
        } catch (error) {
          if (failureNotice) {
            await backupAudit(handle, [failureNotice + publicError(error).error]).catch(() => {});
          }
          throw error;
        }
      });
    } finally {
      operations--;
    }
  }

  async function auditVerifiedWrite(handle, lines) {
    try {
      await backupAudit(handle, lines);
    } catch {
      throw new BackupError('钱包文件已回查，核验日志尚未保存，请检查目录后重试');
    }
  }

  function saveToSelection(json, generatedBatch = false) {
    return withSelectedArchive(async handle => {
      const {receipts, name} = await save(handle, JSON.parse(json), generatedBatch);
      if (receipts.length) await auditVerifiedWrite(handle, auditLines(receipts, '钱包备份回查通过'));
      return name;
    }, '本次钱包备份未通过写入与回查。');
  }

  async function optionalEntry(get) {
    try {
      return await get();
    } catch (error) {
      if (error.name === 'NotFoundError') return null;
      throw error;
    }
  }

  function usageOf(record) {
    const {category, scope, relatedAddress = null} = record;
    const transit = category === 'linked-transit' || category === 'distribution-transit';
    if (!purposeLabels.has(category) || typeof scope !== 'string' || scope.length > 256 ||
        (transit ? typeof relatedAddress !== 'string' || !addressPattern.test(relatedAddress) ||
          /^0x0{40}$/i.test(relatedAddress) : relatedAddress !== null)) {
      throw new BackupError('钱包用途或关联地址无效');
    }
    return {category, scope, relatedAddress: relatedAddress?.toLowerCase() ?? null};
  }

  function usageId(usage) {
    return JSON.stringify([usage.category, usage.scope, usage.relatedAddress]);
  }

  function walletIdentity(record) {
    if (!record || typeof record.address !== 'string' || !addressPattern.test(record.address) ||
        typeof record.privateKey !== 'string' || !keyPattern.test(record.privateKey)) {
      throw new BackupError('钱包备份记录格式无效');
    }
    return {address: record.address.toLowerCase(), privateKey: '0x' + record.privateKey.toLowerCase().replace(/^0x/, '')};
  }

  const badArchive = 'wallets.json 格式或内容异常，已保留原文件';
  function decodeArchive(bytes) {
    try {
      const text = new TextDecoder('utf-8', {fatal: true}).decode(bytes);
      const archive = JSON.parse(text);
      // JSON.parse accepts duplicate keys and keeps only the last value. Never
      // rewrite such a file: an earlier "wallets" array could contain other keys.
      const objects = [];
      for (const token of text.matchAll(/"(?:[^"\\]|\\.)*"(\s*:)?|[{}]/g)) {
        if (token[0] === '{') objects.push(new Set());
        else if (token[0] === '}') objects.pop();
        else if (token[1]) {
          const name = JSON.parse(token[0].slice(0, -token[1].length));
          const names = objects[objects.length - 1];
          if (names.has(name)) throw new Error();
          names.add(name);
        }
      }
      if (archive?.format !== format || !Array.isArray(archive.wallets)) throw new Error();
      return archive;
    } catch {
      throw new BackupError(badArchive);
    }
  }

  function merge(archive, records) {
    const wallets = new Map();
    const keys = new Map();
    const usages = new Map();
    for (const entry of archive.wallets) {
      try {
        const {address, privateKey} = walletIdentity(entry);
        if (wallets.has(address) || keys.has(privateKey) || typeof entry.purpose !== 'string' ||
            !entry.purpose.trim() || !Array.isArray(entry.usages) || !entry.usages.length) throw new Error();
        const identities = new Set(entry.usages.map(u => {
          if (!Object.hasOwn(u, 'relatedAddress')) throw new Error();
          return usageId(usageOf(u));
        }));
        if (identities.size !== entry.usages.length) throw new Error();
        wallets.set(address, entry);
        keys.set(privateKey, address);
        usages.set(address, identities);
      } catch {
        throw new BackupError(badArchive);
      }
    }

    const receipts = [];
    for (const input of records) {
      const {address, privateKey} = walletIdentity(input);
      const usage = usageOf(input);
      const firstCategory = input.originalCategory ?? usage.category;
      if (!purposeLabels.has(firstCategory)) throw new BackupError('钱包首次用途无效');
      let entry = wallets.get(address);
      if ((keys.has(privateKey) && keys.get(privateKey) !== address) ||
          (entry && walletIdentity(entry).privateKey !== privateKey)) {
        throw new BackupError('钱包地址与已有私钥记录冲突，已保留原文件');
      }
      if (!entry) {
        entry = {address, privateKey, purpose: purposeLabels.get(firstCategory), usages: []};
        archive.wallets.push(entry);
        wallets.set(address, entry);
        keys.set(privateKey, address);
        usages.set(address, new Set());
      }
      const seen = usages.get(address);
      const id = usageId(usage);
      const created = !seen.has(id);
      if (created) {
        entry.usages.push(usage);
        seen.add(id);
      }
      receipts.push({category: usage.category, address, created});
    }
    return receipts;
  }

  // Reopen through the selected folder. A detached handle can remain readable.
  async function readCurrent(root, fileHandle) {
    const base = await root.getDirectoryHandle(folder);
    const current = await base.getFileHandle(archiveName);
    const path = await root.resolve(current);
    if (!await current.isSameEntry(fileHandle) || path?.length !== 2 ||
        path[0] !== folder || path[1] !== archiveName) {
      throw new BackupError('备份文件位置已变化，请检查目录再重试');
    }
    return new Uint8Array(await (await current.getFile()).arrayBuffer());
  }

  async function verifyBytes(root, file, expected, error) {
    const current = await readCurrent(root, file);
    if (current.length !== expected.length || !expected.every((byte, i) => byte === current[i])) {
      throw new BackupError(error);
    }
  }

  async function readArchive(root, create = false) {
    const base = await root.getDirectoryHandle(folder, {create});
    const existing = await optionalEntry(() => base.getFileHandle(archiveName));
    const original = existing ? await readCurrent(root, existing) : new Uint8Array();
    const archive = existing ? decodeArchive(original) : {format, wallets: []};
    return {base, existing, original, archive};
  }

  async function save(root, records, generatedBatch) {
    if (!Array.isArray(records)) throw new BackupError('钱包备份记录格式无效');
    const batchId = records[0]?.scope;
    if (generatedBatch && (!groupAddress.test(batchId) ||
        !records.every(r => r?.category === 'tool-generated' && r.scope === batchId))) {
      throw new BackupError('请一次保存一个完整的生成钱包组');
    }
    if (!records.length) return {receipts: []};
    const snapshot = await readArchive(root, true);
    const receipts = merge(snapshot.archive, records);
    const groups = validateGeneratedGroups(snapshot.archive);
    const savedScopes = new Set(records.filter(r => r.category === 'tool-generated').map(r => r.scope));
    let changed = receipts.some(r => r.created);
    let number = 0;
    for (const group of groups.values()) {
      number++;
      if (group.deleted && savedScopes.has(group.id === 'legacy' ? '' : group.id)) {
        throw new BackupError('这个生成钱包组已删除，请重新选择同一目录载入');
      }
      if (group.id === 'legacy' || group.name !== null || !savedScopes.has(group.id)) continue;
      group.name = '第 ' + number + ' 组';
      (snapshot.archive.generatedGroupNames ??= {})[group.id] = group.name;
      changed = true;
    }
    if (changed) {
      await commitArchive(root, snapshot);
    } else {
      await verifyBytes(root, snapshot.existing, snapshot.original, '已有备份与读取内容不一致，请重试');
    }
    return {receipts, name: generatedBatch ? groups.get(batchId).name : undefined};
  }

  async function commitArchive(root, {base, existing, original, archive}) {
    const text = JSON.stringify(archive, null, 2) + '\n';
    const expected = new TextEncoder().encode(text);
    const file = existing || await base.getFileHandle(archiveName, {create: true});
    let output;
    try {
      // The browser commits the replacement on close. Abort if the original
      // on disk changed while this tab was preparing or staging the merge.
      output = await file.createWritable({mode: 'exclusive'});
      await output.write(text);
      await verifyBytes(root, file, original, '备份文件已由其他程序修改，请重试');
      await output.close();
      output = null;
      await verifyBytes(root, file, expected, '备份写入后校验失败，请检查目录再重试');
    } catch (error) {
      if (output) await output.abort().catch(() => {});
      // Unlink only a new, still-empty placeholder from this failed first write.
      if (!existing) {
        try {
          const current = await base.getFileHandle(archiveName);
          if (await file.isSameEntry(current) && (await current.getFile()).size === 0) await base.removeEntry(archiveName);
        } catch { /* Preserve the original failure if the entry is no longer accessible. */ }
      }
      throw error;
    }
  }

  const groupAddress = /^0x[0-9a-f]{40}$/;
  function validGroupName(name) {
    return typeof name === 'string' && name.length > 0 && name.length <= 64 &&
      name === name.trim() && !/[\u0000-\u001f\u007f-\u009f]/u.test(name);
  }

  function validateGeneratedGroups(archive) {
    const groups = new Map();
    for (const wallet of archive.wallets) {
      const uses = wallet.usages.filter(u => u.category === 'tool-generated');
      if (!uses.length) continue;
      if (uses.length !== 1) throw new BackupError('生成钱包被重复分组，请检查备份文件');
      const id = uses[0].scope || 'legacy';
      if (uses[0].scope !== '' && !groupAddress.test(id)) throw new BackupError('生成钱包组标识无效，请检查备份文件');
      if (!groups.has(id)) groups.set(id, {id, name: null, wallets: []});
      groups.get(id).wallets.push(walletIdentity(wallet));
    }
    for (const group of groups.values()) {
      if (group.id !== 'legacy' && !group.wallets.some(w => w.address === group.id)) {
        throw new BackupError('生成钱包组缺少对应首地址，请检查备份文件');
      }
    }
    if (Object.hasOwn(archive, 'generatedGroupNames')) {
      const names = archive.generatedGroupNames;
      if (!names || typeof names !== 'object' || Array.isArray(names)) throw new BackupError(badArchive);
      for (const [id, name] of Object.entries(names)) {
        if (!groups.has(id) || !validGroupName(name)) throw new BackupError('生成钱包组名称记录无效，请检查备份文件');
        groups.get(id).name = name;
      }
    }
    if (Object.hasOwn(archive, 'deletedGeneratedGroups')) {
      const deleted = archive.deletedGeneratedGroups;
      if (!Array.isArray(deleted)) throw new BackupError(badArchive);
      for (const id of deleted) {
        const group = groups.get(id);
        if (!group || group.deleted) throw new BackupError(badArchive);
        group.deleted = true;
      }
    }
    return groups;
  }

  function generatedGroups() {
    return withSelectedArchive(async root => {
      const {archive} = await readArchive(root);
      // Apply the same identity and usage checks as writes before exposing any keys.
      merge(archive, []);
      return Array.from(validateGeneratedGroups(archive).values()).filter(group => !group.deleted);
    });
  }

  function renameGeneratedGroup(id, expectedName, requestedName) {
    if ((id !== 'legacy' && !(typeof id === 'string' && groupAddress.test(id))) ||
        typeof expectedName !== 'string' || typeof requestedName !== 'string') {
      throw new BackupError('生成钱包组信息无效');
    }
    const name = requestedName.trim();
    if (!validGroupName(name) || /[\u0000-\u001f\u007f-\u009f]/u.test(requestedName)) {
      throw new BackupError('组名须为 1–64 个字符，且不能包含控制字符');
    }
    return withSelectedArchive(async root => {
      const snapshot = await readArchive(root);
      merge(snapshot.archive, []);
      const group = validateGeneratedGroups(snapshot.archive).get(id);
      if (!group || group.deleted) throw new BackupError('当前目录没有可编辑的这个生成钱包组，请重新选择目录载入');
      if (group.name === name) {
        await verifyBytes(root, snapshot.existing, snapshot.original, '组名与回查内容不一致，请重试');
      } else {
        if ((group.name ?? '') !== expectedName) {
          throw new BackupError('组名已在其他窗口更改，请重新选择同一目录载入');
        }
        (snapshot.archive.generatedGroupNames ??= {})[id] = name;
        await commitArchive(root, snapshot);
      }
      await auditVerifiedWrite(root, ['生成钱包组改名回查通过 · ' + id]);
    }, '生成钱包组改名未通过 · ' + id + '。');
  }

  function deleteGeneratedGroup(id, expectedName) {
    if ((id !== 'legacy' && !(typeof id === 'string' && groupAddress.test(id))) ||
        typeof expectedName !== 'string') {
      throw new BackupError('生成钱包组信息无效');
    }
    return withSelectedArchive(async root => {
      const snapshot = await readArchive(root);
      merge(snapshot.archive, []);
      const group = validateGeneratedGroups(snapshot.archive).get(id);
      if (!group) throw new BackupError('当前目录没有这个生成钱包组，请重新选择目录载入');
      if (group.deleted) {
        await verifyBytes(root, snapshot.existing, snapshot.original, '删除标记与回查内容不一致，请重试');
      } else {
        if ((group.name ?? '') !== expectedName) {
          throw new BackupError('组名已在其他窗口更改，请重新选择同一目录载入');
        }
        (snapshot.archive.deletedGeneratedGroups ??= []).push(id);
        await commitArchive(root, snapshot);
      }
      await auditVerifiedWrite(root, ['生成钱包组删除标记回查通过 · ' + id]);
    }, '生成钱包组删除标记未通过 · ' + id + '。');
  }

  function publicError(error) {
    // Native exceptions and JSON errors may echo paths or corrupted key material.
    let message = '无法完成本机备份，请检查目录、文件及可用空间后重试';
    if (error instanceof PermissionError) return {error: error.message, code: 'permission'};
    if (error?.name === 'NotAllowedError' || error?.name === 'SecurityError') {
      return {error: '无法访问备份目录，请重新选择并授予读写权限', code: 'permission'};
    }
    if (error instanceof BackupError) message = error.message;
    else if (error?.name === 'QuotaExceededError') message = '本机空间不足，请释放空间后重试';
    else if (error?.name === 'NotFoundError') message = '备份目录或文件已移动或删除，请重新选择备份目录';
    else if (error?.name === 'NoModificationAllowedError') message = '备份目录或文件无法写入，请检查只读设置或文件占用后重试';
    return {error: message};
  }
  function auditLines(receipts, result) {
    const lines = [];
    for (let i = 0; i < receipts.length; i += 24) {
      const names = receipts.slice(i, i + 24).map(({category, address, created}) =>
        (created ? '新建 ' : '已有 ') + purposeLabels.get(category) + '/' + address);
      lines.push(result + ' · ' + names.join('，'));
    }
    return lines;
  }
  async function reply(action) {
    try {
      return JSON.stringify({value: await action() ?? null});
    } catch (error) {
      return JSON.stringify(publicError(error));
    }
  }

  let historyModule;
  let historyLog;
  let historyDirectory;
  let historyGranted = false;
  let historyQueue = Promise.resolve();
  const incomingLogs = [];

  async function bindHistory(log, handle) {
    const granted = !!handle && await handle.queryPermission(permission).catch(() => 'denied') === 'granted';
    if (handle !== historyDirectory || granted !== historyGranted) {
      await log.attach(handle ?? null, granted);
      historyDirectory = handle;
      historyGranted = granted;
    }
    return granted;
  }

  function withHistory(work, owner = selected) {
    const job = historyQueue.then(async () => {
      if (!work && !incomingLogs.length && !historyLog?.snapshot().pending) return;
      const {localExecutionLog} = await (historyModule ??= import('./execution-history.js').catch(error => { historyModule = null; throw error; }));
      historyLog = localExecutionLog;
      while (incomingLogs.length) {
        const handle = incomingLogs[0].handle;
        await bindHistory(historyLog, handle);
        let count = 0;
        while (count < incomingLogs.length && incomingLogs[count].handle === handle) {
          const entry = incomingLogs[count++];
          historyLog.record(entry.level, entry.text, entry.time);
        }
        incomingLogs.splice(0, count);
      }
      if (work) return work(historyLog, await bindHistory(historyLog, owner));
      if (owner) {
        if (!await bindHistory(historyLog, owner)) throw new PermissionError('备份目录授权已失效，请重新选择并授予读写权限');
        await flushActiveLog(historyLog);
      }
    });
    historyQueue = job.catch(() => {});
    return job;
  }

  function recordLog(text, level, time) {
    // Retain events even while the module is loading or the folder is inaccessible.
    incomingLogs.push({handle: selected, text, level, time});
    return withHistory();
  }

  async function flushActiveLog(log) {
    try {
      await log.flushActive();
    } catch {
      throw new BackupError(log.snapshot().error || '本机日志未能写入并回查，请检查 logs.json 和目录权限后重试');
    }
  }

  function verifyHistory(handle) {
    return withHistory((log, granted) => {
      if (!granted) throw new PermissionError('备份目录授权已失效，请重新选择并授予读写权限');
      return flushActiveLog(log);
    }, handle);
  }
  function backupAudit(handle, lines) {
    return withHistory(async (log, connected) => {
      for (let i = 0; i < lines.length; i += 32) {
        for (const line of lines.slice(i, i + 32)) log.record('备份', line);
        if (connected) await log.flushActive();
      }
      if (!connected) throw new PermissionError('备份目录授权已失效');
    }, handle);
  }

  globalThis.uagentWalletBackup = Object.freeze({
    get supported() { return supported(); },
    get hasPendingLogs() { return !!incomingLogs.length || !!historyLog?.snapshot().pending; },
    reconnect: () => reply(reconnect),
    chooseDirectory: () => reply(chooseDirectory),
    checkAccess: () => reply(checkAccess),
    save: json => reply(() => saveToSelection(json)),
    saveGeneratedBatch: json => reply(() => saveToSelection(json, true)),
    generatedGroups: () => reply(generatedGroups),
    renameGeneratedGroup: (id, expectedName, name) => reply(() => renameGeneratedGroup(id, expectedName, name)),
    deleteGeneratedGroup: (id, expectedName) => reply(() => deleteGeneratedGroup(id, expectedName)),
    recordLog: (text, level, time) => reply(() => recordLog(text, level, time)),
    history: () => reply(() => withHistory(async (log, connected) => {
      if (!connected) throw new BackupError('请先连接本机备份目录');
      try {
        return await log.readHistory();
      } catch {
        throw new BackupError('无法读取完整的本机日志，请检查 logs.json 和目录权限后重试');
      }
    })),
    flushHistory: () => reply(() => selected ? verifyHistory(selected) : withHistory()),
  });
})();
