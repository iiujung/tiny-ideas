#!/bin/zsh
# FileDir for Mac
# 把這個檔案放進照片/影片所在的資料夾，雙擊執行，可選擇：
#   1. 整理：依「拍攝日期」把檔案搬進  年/年-月  資料夾
#   2. 刪除重複：找出內容完全相同的檔案，用網頁並排對照，勾選後移到垃圾桶
#
# 日期來源順序：
#   1. 照片的 Exif 拍攝日期／影片裡記錄的建立時間
#   2. 檔名裡的日期（例如 20240522_213703.jpg、1655694782166.jpg）
#   3. 都沒有時，改用檔案的建立日期或修改日期（取較早的）

# ===== 可調整的設定 =====
# 資料夾格式（使用 date 的格式字元）：
#   "%Y/%Y-%m"           → 2022/2022-05（預設）
#   "%Y/%Y-%m/%Y-%m-%d"  → 2022/2022-05/2022-05-01
#   "%Y-%m-%d"           → 2022-05-01
FOLDER_FORMAT="%Y/%Y-%m"

# 要處理的副檔名（不分大小寫）
EXTENSIONS=(jpg jpeg heic heif png gif tif tiff webp dng cr2 cr3 nef arw raf orf rw2
            mov mp4 m4v avi 3gp mts m2ts mkv)
# =======================

setopt nullglob nocaseglob extendedglob
# 只載入 zstat（整個 zsh/stat 模組會蓋掉系統的 stat 指令）
zmodload -F zsh/stat b:zstat
# 終端機沒設定語系時，中文檔名會變亂碼，這裡固定用 UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

cd "${0:A:h}" || exit 1
PATTERN="*.(${(j:|:)EXTENSIONS})"
REPORT="重複檔案對照.html"
THUMBS=".filedir-預覽圖"

cleanup_report() { rm -f -- "$REPORT"; rm -rf -- "$THUMBS" }
trap cleanup_report EXIT

pause() { echo; read -u0 "?按 Enter 回到選單…" }
# 清掉使用者不小心多打或貼上的字，避免影響下一個問題
flush_input() { local _c; while read -u0 -t 0 -k1 _c; do :; done }

# $1 檔案, $2 日期格式
get_date() {
  local f="$1" fmt="$2" raw fs name="${1:t}"
  if [[ "${f:e:l}" == (mov|mp4|m4v|avi|3gp|mts|m2ts|mkv) ]]; then
    # 影片：影片裡記錄的建立時間（跟檔案建立時間相同的話，代表影片本身沒有記錄，略過）
    raw=$(mdls -raw -name kMDItemContentCreationDate -- "$f" 2>/dev/null)
    fs=$(mdls -raw -name kMDItemFSCreationDate -- "$f" 2>/dev/null)
    if [[ -n "$raw" && "$raw" != "(null)" && "$raw" != "$fs" ]]; then
      date -j -f "%Y-%m-%d %H:%M:%S %z" "$raw" "+$fmt" 2>/dev/null && return
    fi
  else
    # 照片：Exif 拍攝日期
    raw=$(sips -g creation "./$f" 2>/dev/null | awk -F': ' '/creation:/ {print $2}')
    if [[ "$raw" == <->:<->:<->\ <->:<->:<-> ]]; then
      date -j -f "%Y:%m:%d %H:%M:%S" "$raw" "+$fmt" 2>/dev/null && return
    fi
  fi
  # 檔名裡的 13 位數時間戳記，例如 1655694782166.jpg、LINE_MOVIE_1582016021707.mp4
  if [[ "$name" =~ '(^|[^0-9])(1[3-9][0-9]{11})([^0-9]|$)' ]]; then
    date -r $(( ${match[2]} / 1000 )) "+$fmt" && return
  fi
  # 檔名裡的日期，例如 20240522_213703.jpg、Screenshot_20240226_214820_LINE.jpg
  # （前面不能緊接著數字，避免從一長串數字中間誤抓）
  if [[ "$name" =~ '(^|[^0-9])((19|20)[0-9]{2})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])' ]]; then
    local d="${match[2]}${match[4]}${match[5]}" t="120000"
    [[ "${name#*$MATCH}" =~ '^[_ -]?([01][0-9]|2[0-3])([0-5][0-9])([0-5][0-9])' ]] && t="${match[1]}${match[2]}${match[3]}"
    date -j -f "%Y%m%d%H%M%S" "$d$t" "+$fmt" 2>/dev/null && return
  fi
  # 後備：檔案建立時間與修改時間取較早的那個
  # （解壓縮、複製會把建立時間變成「現在」，但修改時間通常會保留原本的日期）
  # 1995 年以前的時間視為無效（有些裝置會寫入 1984-01-24 這種預設值）
  local born=$(stat -f %B -- "$f") mod=$(stat -f %m -- "$f") valid=788918400
  (( born > valid && born < mod )) || born=$mod
  date -r "$born" "+$fmt"
}

# ---------- 功能 1：依日期整理 ----------
# 照片的「拍攝時間｜寬｜高」，用來判斷兩個檔案是不是同一張照片的不同版本。
# 沒有拍攝時間的照片無法判斷，回傳空字串（會被當成不同照片，改名保留）
photo_info() {
  sips -g creation -g pixelWidth -g pixelHeight "./$1" 2>/dev/null |
    awk -F': ' '/creation:/ && ($2 == "" || $2 == "<nil>") {bad=1} NR>1 {s = s $2 "|"} END {if (!bad && NF) print s}'
}

organize() {
  # 只看這一層，不往子資料夾找；目的資料夾已經存在時會直接放進去
  local files=( ${~PATTERN}(.) )
  if (( ${#files} == 0 )); then
    echo "這一層找不到任何照片或影片。"; pause; return
  fi

  # 先決定每個檔案的去向；目的地已有同名檔時分成三種：
  #   same    內容完全相同 → 這個檔案移到垃圾桶
  #   older   同一張照片，目的地是較小的壓縮版 → 目的地那份移到垃圾桶，放入這個原檔
  #   newer   同一張照片，這個檔案比較小 → 這個檔案移到垃圾桶
  #   rename  不同照片剛好同名 → 改名成 _1、_2… 保留
  local -A plan act
  local f d t a b n_same=0 n_older=0 n_newer=0 n_rename=0
  echo "🔍 讀取 ${#files} 個檔案的日期…"
  for f in $files; do
    plan[$f]=$(get_date "$f" "$FOLDER_FORMAT")
    t="${plan[$f]}/$f"
    [[ -e "$t" ]] || continue
    if cmp -s -- "$f" "$t"; then act[$f]=same; (( n_same++ ))
    else
      a=$(photo_info "$f"); b=$(photo_info "$t")
      if [[ -n "$a" && "$a" == "$b" ]]; then
        if (( $(zstat +size -- "$f") > $(zstat +size -- "$t") )); then act[$f]=older; (( n_older++ ))
        else act[$f]=newer; (( n_newer++ )); fi
      else act[$f]=rename; (( n_rename++ )); fi
    fi
  done

  echo
  echo "共 ${#files} 個檔案，將會這樣分類："
  for d in ${(ou)plan}; do
    local same=( ${(M)${(v)plan}:#$d} )
    if [[ -d "$d" ]]; then echo "  $d  (${#same} 個，放進既有資料夾)"
    else echo "  $d  (${#same} 個，新建資料夾)"; fi
  done
  if (( n_same + n_older + n_newer + n_rename )); then
    echo
    echo "目的資料夾裡已經有同名檔案的："
    (( n_same ))   && echo "  $n_same 個內容完全相同 → 這邊這份移到垃圾桶"
    (( n_older ))  && echo "  $n_older 個是同一張照片、資料夾裡那份是較小的壓縮版 → 換成這邊的原檔，壓縮版移到垃圾桶"
    (( n_newer ))  && echo "  $n_newer 個是同一張照片、這邊這份比較小 → 這邊這份移到垃圾桶"
    (( n_rename )) && echo "  $n_rename 個是不同照片剛好同名 → 改名成 _1、_2 保留"
  fi
  echo
  local ans
  read -u0 "ans?確定要開始搬移嗎？輸入 y 後按 Enter："
  [[ "$ans" == [yY] ]] || { echo "已取消。"; return }

  local moved=0 trashed=0 dest target base ext i
  for f in $files; do
    dest="${plan[$f]}"
    target="$dest/$f"
    case "${act[$f]}" in
      same|newer) move_to_trash "$f" && (( trashed++ )); continue ;;
      older) move_to_trash "$target" && (( trashed++ )) ;;
      rename)
        base="${f:r}" ext="${f:e}" i=1
        while [[ -e "$dest/${base}_$i.$ext" ]]; do (( i++ )); done
        target="$dest/${base}_$i.$ext" ;;
    esac
    mkdir -p -- "$dest"
    mv -n -- "$f" "$target" && (( moved++ ))
  done
  echo
  echo "✅ 完成！已搬移 $moved 個檔案。"
  (( trashed )) && echo "🗑  $trashed 個重複的檔案已移到垃圾桶（需要的話可以從垃圾桶救回）。"
}

# ---------- 功能 2：找出並刪除重複檔案 ----------
json_str() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\//\\/}
  print -rn -- "\"$s\""
}

move_to_trash() {
  local f="$1" name="${1:t}" target="$HOME/.Trash/${1:t}" i=1
  while [[ -e "$target" ]]; do
    target="$HOME/.Trash/${name:r} $i.${name:e}"; (( i++ ))
  done
  mv -- "$f" "$target"
}

dedupe() {
  # 包含子資料夾（整理過後的照片也找得到）
  local files=( **/${~PATTERN}(.) )
  if (( ${#files} == 0 )); then
    echo "找不到任何照片或影片。"; pause; return
  fi
  echo "🔍 掃描 ${#files} 個檔案…"

  # 先用檔案大小篩選，大小相同的才計算雜湊值
  local -A bysize byhash
  local f sz h
  for f in $files; do
    sz=$(zstat +size -- "$f")
    bysize[$sz]+="$f"$'\n'
  done
  local group
  for sz group in ${(kv)bysize}; do
    local g=( ${(f)group} )
    (( ${#g} > 1 )) || continue
    for f in $g; do
      h=$(md5 -q -- "$f")
      byhash[$sz-$h]+="$f"$'\n'
    done
  done

  local -a groups
  local key
  for key group in ${(kv)byhash}; do
    local g=( ${(f)group} )
    (( ${#g} > 1 )) && groups+=("$key")
  done

  if (( ${#groups} == 0 )); then
    echo "✅ 沒有找到重複的檔案。"; return
  fi
  echo "找到 ${#groups} 組重複檔案，正在產生對照網頁…"

  # 每個檔案給一個編號；網頁回傳的是編號而不是檔名，避免中文檔名在剪貼簿裡編碼跑掉
  local -a ids idgroup
  TOKEN="$RANDOM$RANDOM$(date +%s)"
  local -A gsize
  mkdir -p -- "$THUMBS"
  local json="[" first=1 gi=0 k=0 thumb
  for key in $groups; do
    local g=( ${(f)byhash[$key]} )
    (( gi++ ))
    gsize[$gi]=${#g}
    (( first )) || json+=","; first=0
    json+="{\"size\":${key%%-*},\"files\":["
    local ff=1
    for f in $g; do
      (( k++ ))
      ids[$k]="$f"; idgroup[$k]=$gi
      # 瀏覽器不支援的格式（HEIC、RAW、TIFF）先轉成 JPG 縮圖給網頁預覽，原檔不動
      thumb=""
      if [[ "${f:e:l}" == (heic|heif|tif|tiff|dng|cr2|cr3|nef|arw|raf|orf|rw2) ]]; then
        sips -s format jpeg -Z 1600 "./$f" --out "$THUMBS/$k.jpg" >/dev/null 2>&1 && thumb="$THUMBS/$k.jpg"
      fi
      (( ff )) || json+=","; ff=0
      json+="{\"id\":$k,\"p\":$(json_str "$f"),\"t\":$(json_str "$thumb"),\"d\":$(json_str "$(get_date "$f" "%Y-%m-%d %H:%M")")}"
    done
    json+="]}"
  done
  json+="]"

  write_report "$json"
  open "$REPORT"

  echo
  echo "👉 已在瀏覽器開啟「$REPORT」。"
  echo "   在網頁上選好要保留的照片，按「複製刪除清單」，"
  echo "   這裡會自動收到，不需要貼上。（按 q 可取消）"
  echo
  echo "⏳ 等待網頁的刪除清單…"

  # 自動偵測剪貼簿；清單第一行要有這次的代碼，避免讀到上一次的舊清單
  local clip ch ans
  while true; do
    clip=( ${(f)"$(pbpaste)"} )
    [[ "${clip[1]}" == "FILEDIR-DELETE-LIST $TOKEN" ]] && break
    if read -u0 -t 1 -k1 ch; then
      [[ "$ch" == [qQ] ]] && { cleanup_report; echo "已取消。"; return }
    fi
  done
  flush_input
  echo "📋 收到刪除清單了！"

  # 安全檢查：只接受這次清單裡的編號，且每組至少留一個
  local -a todel
  local -A delcount seen
  local id
  for id in ${clip[2,-1]}; do
    [[ "$id" == <1-> && -n "${ids[$id]}" && -z "${seen[$id]}" ]] || { echo "  略過無效的項目：$id"; continue }
    seen[$id]=1
    todel+=("$id"); (( delcount[${idgroup[$id]}]++ ))
  done
  local -a final
  for id in $todel; do
    f="${ids[$id]}"
    if (( delcount[${idgroup[$id]}] >= gsize[${idgroup[$id]}] )); then
      echo "  略過（這一組不能全部刪掉）：$f"
    elif [[ ! -f "$f" ]]; then
      echo "  略過（檔案已不存在）：$f"
    else
      final+=("$f")
    fi
  done

  if (( ${#final} == 0 )); then
    echo "沒有要刪除的檔案。"; cleanup_report; return
  fi

  echo
  echo "將把以下 ${#final} 個檔案移到垃圾桶："
  for f in $final; do echo "  $f"; done
  flush_input
  read -u0 "ans?確定嗎？輸入 y 後按 Enter："
  if [[ "$ans" != [yY] ]]; then
    echo "已取消。"; cleanup_report; return
  fi

  local n=0
  for f in $final; do move_to_trash "$f" && (( n++ )); done
  cleanup_report
  echo "🗑  已將 $n 個檔案移到垃圾桶（需要的話可以從垃圾桶救回）。"
}

write_report() {
  cat > "$REPORT" <<'HTML_HEAD'
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>重複檔案對照</title>
<style>
  :root {
    --bg: #f5f5f4; --card: #ffffff; --text: #1c1917; --muted: #78716c;
    --line: #e7e5e4; --keep: #111111; --del: #dc2626; --accent: #111111; --on-accent: #ffffff;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #1c1917; --card: #292524; --text: #f5f5f4; --muted: #a8a29e;
            --line: #44403c; --keep: #fafaf9; --del: #f87171; --accent: #fafaf9; --on-accent: #111111; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 14px/1.5 -apple-system, BlinkMacSystemFont, "PingFang TC", sans-serif; }
  header { position: sticky; top: 0; z-index: 5; background: var(--card);
           border-bottom: 1px solid var(--line); padding: 12px 20px;
           display: flex; flex-wrap: wrap; gap: 12px; align-items: center; }
  header h1 { font-size: 17px; margin: 0; flex: 1 1 auto; }
  #stats { color: var(--muted); }
  button { font: inherit; border: 1px solid var(--line); background: var(--card); color: var(--text);
           border-radius: 8px; padding: 7px 14px; cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent); font-weight: 600; }
  main { padding: 20px; max-width: 1400px; margin: 0 auto; }
  .hint { color: var(--muted); margin: 0 0 16px; }
  .group { background: var(--card); border: 1px solid var(--line); border-radius: 12px;
           padding: 14px; margin-bottom: 18px; }
  .group h2 { font-size: 14px; margin: 0 0 10px; color: var(--muted); font-weight: 500; }
  .items { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
  /* 保留＝選取狀態：黑色外框＋打勾；刪除＝沒有外框，只有刪除標籤 */
  .item { border: 1px solid var(--line); border-radius: 12px; overflow: hidden; cursor: pointer;
          position: relative; background: var(--bg); transition: box-shadow .15s, border-color .15s; }
  .item.keep { border-color: var(--keep); box-shadow: 0 0 0 3px var(--keep); }
  .item.del .thumb { opacity: .4; filter: grayscale(1); }
  .item.del .meta { opacity: .6; }
  .thumb { width: 100%; aspect-ratio: 4/3; object-fit: contain; display: block; background: #0003; }
  .check { position: absolute; top: 10px; left: 10px; width: 28px; height: 28px; border-radius: 50%;
           display: grid; place-items: center; font-size: 16px; font-weight: 700; color: #fff;
           background: #0004; border: 2px solid #fff; box-shadow: 0 1px 3px #0005; }
  .item.keep .check { background: var(--keep); border-color: var(--keep); color: var(--on-accent); }
  .badge { position: absolute; top: 12px; left: 46px; padding: 2px 10px; border-radius: 99px;
           font-weight: 700; font-size: 12px; color: #fff; background: var(--keep); }
  .item.del .badge { background: var(--del); }
  .group h2 b.k { color: var(--keep); }
  .item.keep .badge { color: var(--on-accent); }
  .group h2 b.d { color: var(--del); }
  .zoom { position: absolute; top: 6px; right: 6px; padding: 2px 8px; font-size: 12px; }
  .meta { padding: 8px 10px; word-break: break-all; }
  .meta .name { font-weight: 600; }
  .meta .sub { color: var(--muted); font-size: 12px; }
  #toast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
           background: var(--text); color: var(--bg); padding: 10px 18px; border-radius: 10px;
           opacity: 0; transition: opacity .2s; pointer-events: none; max-width: 90vw; }
  #toast.show { opacity: 1; }
  #viewer { position: fixed; inset: 0; background: #000d; display: none; z-index: 10;
            align-items: center; justify-content: center; cursor: zoom-out; }
  #viewer.show { display: flex; }
  #viewer img, #viewer video { max-width: 95vw; max-height: 95vh; }
  #manual { width: 100%; height: 120px; margin-top: 8px; display: none; }
</style>
</head>
<body>
<header>
  <h1>重複檔案對照</h1>
  <span id="stats"></span>
  <button id="reset">恢復建議</button>
  <button id="copy" class="primary">複製刪除清單</button>
</header>
<main>
  <p class="hint">每一組都是<strong>內容完全相同</strong>的檔案。<strong>點照片選取要保留的</strong>（黑框打勾 ✓），沒選取的會被刪除；每組至少要保留一個。確認後按「複製刪除清單」，再回到終端機輸入 y 確認即可（不需要貼上）。</p>
  <textarea id="manual" readonly></textarea>
  <div id="list"></div>
</main>
<div id="toast"></div>
<div id="viewer"></div>
<script>
HTML_HEAD
  print -r -- "const GROUPS = $1;" >> "$REPORT"
  print -r -- "const TOKEN = '$TOKEN';" >> "$REPORT"
  cat >> "$REPORT" <<'HTML_TAIL'
const VIDEO = /\.(mov|mp4|m4v|avi|3gp|mts|m2ts|mkv)$/i;
const url = p => p.split('/').map(encodeURIComponent).join('/');
const fmtSize = b => b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.round(b / 1024) + ' KB';
const name = p => p.split('/').pop();
const folder = p => p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '（目前資料夾）';
let del = new Set();

// 建議：每組保留檔名最短的那個（通常是原檔，副本常會多「 copy」「(1)」）
function suggest() {
  del = new Set();
  GROUPS.forEach(g => {
    const sorted = [...g.files].sort((a, b) => name(a.p).length - name(b.p).length || a.p.localeCompare(b.p));
    sorted.slice(1).forEach(f => del.add(f.p));
  });
}

function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.classList.add('show');
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 2500);
}

function render() {
  const list = document.getElementById('list');
  list.innerHTML = '';
  GROUPS.forEach((g, gi) => {
    const sec = document.createElement('section');
    sec.className = 'group';
    const nDel = g.files.filter(f => del.has(f.p)).length;
    sec.innerHTML = `<h2>第 ${gi + 1} 組 · ${g.files.length} 個相同檔案 · 每個 ${fmtSize(g.size)} · ` +
      `<b class="k">保留 ${g.files.length - nDel}</b> · <b class="d">刪除 ${nDel}</b></h2>`;
    const items = document.createElement('div');
    items.className = 'items';
    g.files.forEach(f => {
      const card = document.createElement('div');
      card.className = 'item ' + (del.has(f.p) ? 'del' : 'keep');
      const media = VIDEO.test(f.p)
        ? Object.assign(document.createElement('video'), { src: url(f.p), muted: true, preload: 'metadata' })
        : Object.assign(document.createElement('img'), { src: url(f.t || f.p), loading: 'lazy' });
      media.className = 'thumb';
      const dims = document.createElement('span');
      media.addEventListener(media.tagName === 'IMG' ? 'load' : 'loadedmetadata', () => {
        const w = media.naturalWidth || media.videoWidth, h = media.naturalHeight || media.videoHeight;
        if (w) dims.textContent = ` · ${w}×${h}`;
      });
      media.addEventListener('error', () => { dims.textContent = ' · 瀏覽器無法預覽此格式'; });
      const badge = Object.assign(document.createElement('span'), { className: 'badge', textContent: del.has(f.p) ? '刪除' : '保留' });
      const check = Object.assign(document.createElement('span'), { className: 'check', textContent: del.has(f.p) ? '' : '✓' });
      const zoom = Object.assign(document.createElement('button'), { className: 'zoom', textContent: '放大' });
      zoom.onclick = e => { e.stopPropagation(); showViewer(f.t || f.p); };
      const meta = document.createElement('div');
      meta.className = 'meta';
      meta.innerHTML = `<div class="name"></div><div class="sub"></div><div class="sub"></div>`;
      meta.children[0].textContent = name(f.p);
      meta.children[1].textContent = folder(f.p);
      meta.children[2].textContent = f.d;
      meta.children[2].appendChild(dims);
      card.append(media, check, badge, zoom, meta);
      card.onclick = () => toggle(g, f.p);
      items.appendChild(card);
    });
    sec.appendChild(items);
    list.appendChild(sec);
  });
  updateStats();
}

function toggle(g, p) {
  if (del.has(p)) del.delete(p);
  else {
    const kept = g.files.filter(f => !del.has(f.p)).length;
    if (kept <= 1) { toast('每組至少要保留一個檔案'); return; }
    del.add(p);
  }
  render();
}

function updateStats() {
  let bytes = 0;
  GROUPS.forEach(g => g.files.forEach(f => { if (del.has(f.p)) bytes += g.size; }));
  document.getElementById('stats').textContent =
    `${GROUPS.length} 組重複 · 標記刪除 ${del.size} 個 · 可省下 ${fmtSize(bytes)}`;
}

function showViewer(p) {
  const v = document.getElementById('viewer');
  v.innerHTML = '';
  const el = VIDEO.test(p)
    ? Object.assign(document.createElement('video'), { src: url(p), controls: true, autoplay: true })
    : Object.assign(document.createElement('img'), { src: url(p) });
  el.onclick = e => { if (el.tagName === 'VIDEO') e.stopPropagation(); };
  v.appendChild(el);
  v.classList.add('show');
}
document.getElementById('viewer').onclick = function () { this.classList.remove('show'); this.innerHTML = ''; };

document.getElementById('reset').onclick = () => { suggest(); render(); toast('已恢復建議的選擇'); };
document.getElementById('copy').onclick = async () => {
  // 只傳編號，不傳檔名（避免中文檔名在剪貼簿裡編碼跑掉）
  const ids = GROUPS.flatMap(g => g.files).filter(f => del.has(f.p)).map(f => f.id);
  const text = ['FILEDIR-DELETE-LIST ' + TOKEN, ...ids].join('\n');
  let ok = false;
  try { await navigator.clipboard.writeText(text); ok = true; } catch (e) {}
  if (!ok) {
    const ta = document.getElementById('manual');
    ta.value = text; ta.style.display = 'block'; ta.select();
    try { ok = document.execCommand('copy'); } catch (e) {}
  }
  toast(ok ? `已送出 ${del.size} 個要刪除的檔案，請回到終端機輸入 y 確認（不需要貼上）`
           : '無法自動複製，請手動全選上方文字框並按 ⌘C');
};

suggest();
render();
</script>
</body>
</html>
HTML_TAIL
}

# ---------- 主選單 ----------
while true; do
  clear
  echo "📁 FileDir for Mac"
  echo "   資料夾：$PWD"
  echo
  echo "  1) 依拍攝日期整理（年/年-月）"
  echo "  2) 找出並刪除重複檔案"
  echo "  q) 離開"
  echo
  read -u0 "choice?請輸入 1、2 或 q，再按 Enter："; echo
  case $choice in
    1) organize; pause ;;
    2) dedupe; pause ;;
    q|Q) exit 0 ;;
  esac
done
