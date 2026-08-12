# slack-remote - hook Slack cho ac-remote.sh (hướng dẫn cài đặt)

> Bản dịch tiếng Việt của `README.md` (bản tiếng Anh là bản chuẩn; nếu hai bản lệch nhau, tin bản tiếng Anh).

Cặp hook dựng sẵn biến MỘT channel Slack thành kênh ra lệnh từ xa của captain cho MỘT fleet home.
`remote-poll` kéo message mới của captain (lịch sử channel + các thread đã đăng ký) và phát ra dưới dạng các dòng JSON cho `ac-remote.sh poll`.
`remote-reply` đăng trả lời của fleet vào đúng thread qua `chat.postMessage`.
`remote-ack` (tùy chọn) đi một vòng đời reaction trên message của captain - `:eyes:` khi fleet đã ghi nhận bền vững, `:gear:` khi có task gắn vào order, `:white_check_mark:` khi câu trả lời landing đã gửi - captain nhìn emoji là biết order đang ở đâu.
Header comment của mỗi hook là contract chính chủ; trang này chỉ là hướng dẫn cài đặt.
Wire từng fleet một - config nằm theo từng home, nên hai fleet dùng hai channel (hoặc hai app).

## Điều kiện trước

- Một Slack workspace bạn quản trị (hoặc được phép cài app vào).
- Fleet home bạn định wire (ví dụ bên dưới dùng `~/Work/ac-homes/drydock`).
- Máy có `curl` và `jq` (toolchain của distro vốn đã yêu cầu).

## Các bước phía Slack (một lần cho mỗi fleet)

1. Tạo app: https://api.slack.com/apps -> Create New App -> From scratch -> đặt tên theo fleet (ví dụ `ac-drydock`) -> chọn workspace.
2. Cấp scope và cài đặt: OAuth & Permissions -> Bot Token Scopes -> thêm `channels:history`, `groups:history`, `chat:write`, `reactions:write` (cho biên nhận đã-đọc) -> Install to Workspace -> copy bot token (`xoxb-...`).
3. Channel điều khiển: tạo hoặc chọn một channel (private cũng được - scope `groups:history` là để cho trường hợp đó) và mời bot vào: `/invite @<tên-app>`.
4. Lấy hai loại id:
   - Channel ID (`C...`): bấm vào tên channel -> channel details -> ID nằm ở cuối.
   - Member ID của bạn (`U...`): mở profile -> menu ba chấm -> Copy member ID.
     Chỉ message do member ID có trong danh sách viết mới thành lệnh - bộ lọc dựa trên ID, không bao giờ dựa trên tên hiển thị, nên không ai giả mạo được bằng cách đổi tên.
     Hỗ trợ nhiều id (`config/slack-captain-id`, mỗi dòng một id) và MỌI id trong danh sách đều là đồng-captain đầy đủ - lời của họ là lệnh tier-1; chỉ liệt kê những tài khoản bạn kiểm soát hoặc tin tuyệt đối.

## Các bước phía fleet home

5. Ghi config (token nằm ngoài git - `.env` đã được gitignore):

```bash
cd ~/Work/ac-homes/drydock
printf 'SLACK_BOT_TOKEN=xoxb-...\n' >> .env && chmod 600 .env
printf 'C0XXXXXXX\n' > config/slack-channel
printf 'U0XXXXXXX\n' > config/slack-captain-id           # mỗi dòng một id; thêm dòng cho đồng-captain
```

6. Copy cặp hook vào chỗ và cấp quyền chạy (slot poll của watcher và ride-along lúc drain kích hoạt theo điều kiện `config/remote-poll` CÓ QUYỀN THỰC THI):

```bash
cd ~/Work/agent-crew
cp docs/examples/slack-remote/remote-poll docs/examples/slack-remote/remote-reply \
   docs/examples/slack-remote/remote-ack ~/Work/ac-homes/drydock/config/
chmod +x ~/Work/ac-homes/drydock/config/remote-poll ~/Work/ac-homes/drydock/config/remote-reply \
         ~/Work/ac-homes/drydock/config/remote-ack
```

7. Kiểm tra đầu-cuối: post một message thử vào channel (từ một tài khoản captain trong danh sách), rồi chạy:

```bash
cd ~/Work/agent-crew && AC_HOME=~/Work/ac-homes/drydock bin/ac-remote.sh poll
```

Thấy một dòng `remote-order sl-C...-...` nghĩa là đường ống đã thông.
Muốn xem JSON thô thì chạy thẳng `"$AC_HOME/config/remote-poll"` - cwd nào cũng được, chỉ cần có `AC_HOME`.

## Sau khi cài xong, hệ vận hành thế nào

- Watcher fleet đang giữ lock poll mỗi `AC_REMOTE_POLL` giây (mặc định 300); watcher scoped của roomchief không bao giờ poll, nên toàn fleet chỉ có đúng một poller.
- Message mới của captain trở thành wake bền `remote-order <rid>`; crewchief đọc lệnh từ đĩa (`ac-remote.sh show <rid>`) và chạy đúng thang attribution lời-captain như trong chat (skill `remote-orders` giữ phần cơ chế).
- Mọi quyết định đều được receipt `DECIDED:` vào room của family VÀ echo ngược lại thread Slack.
- Các mục đang chờ captain (gate, ask) được push lúc wake-drain thành MỘT message gộp cho mỗi thread family; trả lời bên trong thread của family nào là câu trả lời tự gắn vào family đó.
- Task được spawn từ lệnh remote sẽ được link (`ac-remote.sh link`) để khi land tự post follow-up vào đúng thread đã ra lệnh.
- Xác nhận hủy diệt (`--force` discard, xóa repo) bị từ chối qua remote - fleet trả lời "answer in the terminal" (AGENTS.md mục 8).

## Ghi chú bảo mật

- Bật 2FA cho MỌI tài khoản captain trong danh sách: mỗi member ID là một chìa khóa chỉ huy từ xa.
- Bot token đọc được channel điều khiển và đăng bài dưới danh nghĩa fleet - coi nó như credential (`chmod 600 .env`; lộ thì rotate ngay trên trang app Slack).
- Token chỉ di chuyển bên trong header file của curl (0600, xóa khi thoát), không bao giờ nằm trong argv hay output.
- Text của message remote bị coi là không đáng tin ở mọi nơi: không bao giờ chạm shell mà không quote, và chỉ rid đã qua slug-guard mới được thành tên file.

## Xử lý sự cố

- `poll` không in gì: không có message MỚI nào do captain viết kể từ cursor; post lại từ một tài khoản captain trong danh sách (message của bot và user ngoài danh sách bị drop by design).
- `remote-poll` thoát 0 im lặng khi chưa config: cố ý - hook trơ cho đến khi làm xong bước 5.
- `remote-reply` báo lỗi to khi thiếu config: cố ý - một câu trả lời gate không bao giờ được phép biến mất trong im lặng.
- Đọc lại lịch sử từ đầu: xóa `state/.slack-cursor` (channel) hoặc `state/remote-threads/<rid>.thread` (một thread); rid đã stash sẽ tự dedup, nhưng rid đã bị `gc` dọn sẽ quay lại như lệnh mới.
- Lệnh mồ côi (đã stash nhưng chưa từng wake, ví dụ crash giữa lúc poll): `ac-remote.sh gc` liệt kê chúng dưới dạng advisory `unwoken <rid>` trên stderr.
- Lỗi auth trong log `state/`: kiểm tra lại scope của token (channel private cần `groups:history`) và bot đã được mời vào channel chưa.
