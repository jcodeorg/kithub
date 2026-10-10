// esp-web-tools 9.x の画面文言を日本語に置き換える。
// 公式に多言語対応がないため、ボタンとダイアログの Shadow DOM 内のテキストを辞書で書き換える。
(() => {
  const exact = {
    'Connect': '接続',
    'CONNECT': '接続',
    'Install': 'インストール',
    'Back': '戻る',
    'Next': '次へ',
    'Continue': '続ける',
    'Close': '閉じる',
    'Cancel': 'キャンセル',
    'Skip': 'スキップ',
    'Try Again': '再試行',
    'Error': 'エラー',
    'Disconnected': '切断されました',
    'Connecting': '接続中',
    'Device Dashboard': 'デバイスダッシュボード',
    'Logs': 'ログ',
    'Logs & Console': 'ログとコンソール',
    'Download Logs': 'ログをダウンロード',
    'Reset Device': 'デバイスをリセット',
    'Visit Device': 'デバイスを開く',
    'Add to Home Assistant': 'Home Assistant に追加',
    'Fund Development': '開発を支援',
    'Erase device': 'デバイスを消去',
    'Erase User Data': 'ユーザーデータを消去',
    'Confirm Installation': 'インストールの確認',
    'Installing': 'インストール中',
    'Preparing installation': 'インストールを準備中',
    'Erasing': '消去中',
    'Wrapping up': '仕上げ中',
    'Installation complete!': 'インストールが完了しました！',
    'Installation failed': 'インストールに失敗しました',
    'Configure Wi-Fi': 'Wi-Fi の設定',
    'Connect to Wi-Fi': 'Wi-Fi に接続',
    'Change Wi-Fi': 'Wi-Fi を変更',
    'Device connected to the network!': 'デバイスがネットワークに接続されました！',
    'Scanning for networks': 'ネットワークを検索中',
    'Trying to connect': '接続を試行中',
    'Unable to connect': '接続できません',
    'Timeout': 'タイムアウト',
    'Network': 'ネットワーク',
    'Network Name': 'ネットワーク名',
    'Password': 'パスワード',
    'Join other…': 'その他のネットワーク…',
    'No port selected': 'ポートが選択されていません',

    'Do you want to': '次の操作を実行しますか？ ',
    'install': 'インストール: ',
    'update to': '更新: ',
    '?': '',
    '.': '',
    'Your device is running': '現在のファームウェア: ',
    'All data on the device will be erased.': 'デバイス上のすべてのデータが消去されます。',
    'Do you want to erase the device before installing': 'インストール前にデバイスを消去しますか？ 対象: ',
    '? All data on the device will be lost.': 'デバイス上のすべてのデータが失われます。',
    'Do you want to reset your device and erase all user data from your device?': 'デバイスをリセットして、すべてのユーザーデータを消去しますか？',
    'This will take': '所要時間: 約 ',
    'a minute': '1分',
    '2 minutes': '2分',
    'Keep this page visible to prevent slow down': '速度低下を防ぐため、このページを表示したままにしてください',
    'Enter the credentials of the Wi-Fi network that you want your device to connect to.': 'デバイスを接続する Wi-Fi ネットワークの認証情報を入力してください。',

    'You can only install ESP devices on HTTPS websites or on the localhost.': 'ESP デバイスへのインストールは HTTPS のサイトまたは localhost でのみ行えます。',
    'Your browser does not support installing things on ESP devices. Use Google Chrome or Microsoft Edge.': 'お使いのブラウザは ESP デバイスへの書き込みに対応していません。Google Chrome または Microsoft Edge を使用してください。',
    'Your browser does not support installing things on ESP devices. Use Mozilla Firefox, Google Chrome or Microsoft Edge.': 'お使いのブラウザは ESP デバイスへの書き込みに対応していません。Google Chrome または Microsoft Edge を使用してください。',

    "If you didn't select a port because you didn't see your device listed, try the following steps:": 'デバイスが一覧に表示されず、ポートを選択できなかった場合は、次の手順を試してください。',
    'Make sure that the device is connected to this computer (the one that runs the browser that shows this website)': 'デバイスが、このサイトを表示しているブラウザのコンピューターに接続されていることを確認してください。',
    'Most devices have a tiny light when it is powered on. If yours has one, make sure it is on.': '多くのデバイスは電源が入ると小さなランプが点灯します。ランプがある場合は点灯していることを確認してください。',
    'Make sure that the USB cable you use can be used for data and is not a power-only cable.': '使用している USB ケーブルが、充電専用ではなくデータ通信に対応していることを確認してください。',
    'Make sure you have the right drivers installed. Below are the drivers for common chips used in ESP devices:': '正しいドライバーがインストールされていることを確認してください。ESP デバイスで一般的なチップのドライバーは次のとおりです。',
    'Windows & Mac': 'Windows / Mac',
    'Windows': 'Windows',
    'Mac': 'Mac',
    '(download via blue button with': '（ダウンロードは次のアイコンの青いボタンから:',
    'icon)': '）',
  };

  const rules = [
    [/^Install (.+)$/, '$1 をインストール'],
    [/^Update (.+)$/, '$1 を更新'],
    [/^Unknown error \((.+)\)$/, '不明なエラー ($1)'],
    [/^(CP2102|CH342, CH343, CH9102|CH340, CH341) drivers:$/, '$1 のドライバー:'],
  ];

  const selector = 'esp-web-install-button, ewt-install-dialog, ewt-no-port-picked-dialog';
  const seen = new WeakSet();

  function translate(text) {
    const key = text.replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
    if (!key) return null;
    if (Object.hasOwn(exact, key)) return exact[key];
    for (const [re, out] of rules) {
      if (re.test(key)) return key.replace(re, out);
    }
    return null;
  }

  const observer = new MutationObserver(() => {
    roots.forEach((el) => (el.isConnected ? scan(el) : roots.delete(el)));
  });
  const roots = new Set();

  function walk(node) {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        const out = translate(child.data);
        if (out !== null && out !== child.data) child.data = out;
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        if (child.shadowRoot) watchRoot(child.shadowRoot);
        walk(child);
      }
    }
  }

  function watchRoot(root) {
    if (!seen.has(root)) {
      seen.add(root);
      observer.observe(root, { subtree: true, childList: true, characterData: true });
    }
    walk(root);
  }

  function scan(el) {
    if (el.shadowRoot) watchRoot(el.shadowRoot);
  }

  function attach(el) {
    roots.add(el);
    if (el.shadowRoot) {
      scan(el);
    } else {
      requestAnimationFrame(() => attach(el));
    }
  }

  function collect(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node.matches(selector)) attach(node);
    node.querySelectorAll(selector).forEach(attach);
  }

  new MutationObserver((records) => {
    records.forEach((r) => r.addedNodes.forEach(collect));
  }).observe(document.body, { childList: true, subtree: true });

  collect(document.body);
})();
