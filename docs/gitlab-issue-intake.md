# Tiếp nhận issue GitLab

Hướng dẫn vận hành cho luồng giao việc bằng issue GitLab: người dùng mở issue và gắn một label, first mate nhận việc, chia nhỏ, làm bằng merge request, rồi trả trạng thái ngược lại bằng label.

Toàn bộ trạng thái của luồng sống trên GitLab, không nằm trong một hệ thống riêng nào khác.
Không có webhook và không có server nhận sự kiện: một poll nhỏ chạy nền trên máy chạy first mate, phát hiện thay đổi thì đánh thức first mate.
Vì vậy độ trễ của luồng là một chu kỳ poll, không phải tức thời.

Tài liệu này dẫn bạn đi qua các bước theo thứ tự và trỏ tới nơi sở hữu từng chi tiết.
Schema cấu hình thuộc về [`docs/configuration.md`](configuration.md) mục "GitLab issue intake (config/gitlab-issues.json)".
Cơ chế poll, dòng báo cáo, các bản ghi riêng và nhịp báo lỗi thuộc về header của [`bin/fm-gitlab-issues.sh`](../bin/fm-gitlab-issues.sh).
Các thao tác đọc và ghi lên một issue, cùng giới hạn cứng của chúng, thuộc về header của [`bin/fm-gitlab-issue.sh`](../bin/fm-gitlab-issue.sh).
Đọc header của script trước khi dùng lần đầu; tài liệu này không chép lại chúng.

Ví dụ trong tài liệu dùng host `<host>` và group `<group>`, thay bằng host và group của bạn.
Khi cần một ví dụ cụ thể, tài liệu dùng group giả định `team/platform` trên `gitlab.example.com`, gồm hai project `api-service` và `web-app`, nhánh mặc định `main`.
Host, group và tên project thật của bạn chỉ nằm trong file cấu hình local `config/gitlab-issues.json`, file đó được gitignore nên các định danh hạ tầng nội bộ không đi vào lịch sử công khai của repo này.

## Bước 1: tài khoản bot và đăng nhập

Luồng này cần một tài khoản riêng cho first mate, không dùng chung tài khoản người thật.
Lý do là mọi comment và mọi thay đổi label do first mate thực hiện sẽ hiện tên tài khoản đó, nên người đọc phân biệt được ngay đâu là máy và đâu là người.

Yêu cầu tối thiểu:

- Một bot account hoặc group access token có quyền **Developer** trên group.
  Developer đủ để đọc issue, đặt label, viết comment và mở merge request.
  Không cấp Maintainer: luồng này không cần merge và không nên có quyền merge.
- Token dạng Personal Access Token hoặc Group Access Token với scope `api`.
- `glab` và `jq` có trên `PATH` của máy chạy first mate.

Trên máy chạy first mate, đăng nhập bằng token đó:

```sh
glab auth login --hostname <host>
```

Token chỉ nằm trong config của `glab` trên máy đó và không bao giờ được ghi vào bất kỳ file nào trong repo này.
Không có script nào của first mate đọc, lưu hay in token ra.
Nếu `glab auth status --hostname <host>` báo token đang nằm ở dạng plaintext trong file config, chạy lại `glab auth login --hostname <host>` để chuyển nó vào keyring của hệ điều hành.

Kiểm tra lại trước khi đi tiếp:

```sh
glab auth status --hostname <host>
```

## Bước 2: tạo bảy label ở cấp group

Bảy label `fm::*` phải được tạo ở **cấp group**, không tạo lại trong từng project.
Tạo ở cấp group thì mọi project trong group và trong các subgroup đều dùng chung một bộ, và thêm project mới về sau không phải tạo lại label.

Tên có dạng `fm::<trạng thái>` để dùng được cơ chế scoped label của GitLab, khi đó một issue chỉ giữ được một label `fm::` tại một thời điểm.

Tạo từng label bằng API group labels:

```sh
glab api --hostname <host> --method POST "groups/<group url-encoded>/labels" \
  --raw-field 'name=fm::todo' --raw-field 'color=#2B6CB0'
```

`<group url-encoded>` là đường dẫn đầy đủ của group với `/` thay bằng `%2F`, ví dụ `team%2Fplatform`.

Lặp lại cho đủ bảy tên: `fm::todo`, `fm::triage`, `fm::plan-review`, `fm::accepted`, `fm::needs-human`, `fm::done`, `fm::human-replied`.
Màu tùy bạn chọn, nhưng nên để ba label người dùng đặt khác màu rõ ràng với bốn label first mate đặt.

Kiểm tra lại:

```sh
glab api --hostname <host> --method GET --paginate "groups/<group url-encoded>/labels?per_page=100" \
  | jq -r '.[] | select(.name | startswith("fm::")) | .name'
```

Tập bảy tên này không phải do tài liệu này định nghĩa.
Nơi định nghĩa duy nhất là biến `FM_LABEL_VOCABULARY` trong [`bin/fm-gitlab-issue.sh`](../bin/fm-gitlab-issue.sh).
Script đó từ chối mọi tên `fm::` nằm ngoài tập này trước khi gửi request, nên gõ sai một tên sẽ không vô tình tạo ra label mới trên GitLab.
Nếu bạn cần đổi hoặc thêm tên, sửa ở đó chứ không phải ở đây.
Nhưng trang này chép lại tên label ở bốn chỗ, danh sách bảy tên ở trên, bảng ở mục "Ba label người dùng cần biết", dòng `intake_labels` trong khối cấu hình mẫu ở "Bước 3", và câu nêu mặc định của `intake_labels` ngay dưới khối đó, nên một thay đổi bộ label buộc phải cập nhật cả bốn chỗ trong tài liệu này chứ không chỉ sửa script.

## Bước 3: viết cấu hình

Luồng được mô tả bằng một file cấu hình local của home đang chạy: `config/gitlab-issues.json`.
File này nằm trong `.gitignore`, không bao giờ được commit, và không được kế thừa sang home của second mate.
Nó không chứa token, chỉ chứa địa chỉ và phạm vi poll.

Một cấu hình đủ dùng cho luồng này:

```json
{
  "host": "<host>",
  "group": "<group>",
  "projects": ["api-service", "web-app"],
  "intake_labels": ["fm::todo", "fm::human-replied", "fm::accepted"],
  "max_in_flight": 3
}
```

Danh sách trường đầy đủ, trường nào bắt buộc, giá trị mặc định và cách một file sai được báo lỗi đều thuộc về [`docs/configuration.md`](configuration.md) mục "GitLab issue intake (config/gitlab-issues.json)"; đọc ở đó, tài liệu này không chép lại.

Một điểm cần chú ý khi viết `intake_labels`.
Mặc định của nó chỉ gồm `fm::todo` và `fm::human-replied`.
Luồng mô tả ở đây cần cả `fm::accepted`, vì đó là cách người dùng duyệt kế hoạch của một issue lớn, nên phải liệt kê đủ ba label thay vì dựa vào mặc định.
Bốn label còn lại không nằm trong `intake_labels`: chúng là trạng thái first mate tự đặt, không phải cách giao việc.

### Bật và tắt poll

Bật một lần cho mỗi home:

```sh
bin/fm-gitlab-issues.sh arm
```

Tắt:

```sh
bin/fm-gitlab-issues.sh disarm
```

`arm` từ chối nếu cấu hình chưa có hoặc sai định dạng, nên lệnh này cũng là bước kiểm tra cấu hình.
Sau khi bật, poll chạy theo nhịp `FM_CHECK_INTERVAL` của watcher (mặc định 300 giây), không có lịch riêng nào khác; xem [`docs/configuration.md`](configuration.md) nếu bạn muốn đổi nhịp đó.
Một home đã bật poll sẽ giữ watcher chạy ngay cả khi không còn việc nào, và `disarm` là cách kết thúc nhu cầu đó.
Chi tiết về việc `arm` và `disarm` ghi và xóa những gì thuộc về header của [`bin/fm-gitlab-issues.sh`](../bin/fm-gitlab-issues.sh).

Xem thử poll đang thấy gì mà không cần chờ watcher:

```sh
bin/fm-gitlab-issues.sh check
bin/fm-gitlab-issues.sh pending
```

`check` im lặng khi không có gì mới, đó là hành vi đúng chứ không phải lỗi.

Một lưu ý khi chạy `check` bằng tay: nó ghi luôn các cặp (issue, label) vừa thấy vào sổ đã báo, nên watcher sẽ không đánh thức first mate về những issue đó nữa.
Chi tiết của chúng vẫn nằm trong danh sách `pending` để first mate đọc, nhưng nếu bạn muốn chắc chắn không cắt mất một lượt đánh thức thì hãy để watcher tự chạy và chỉ dùng `pending` để xem.

## Ba label người dùng cần biết

Bạn chỉ cần nhớ ba label.
Bốn label còn lại do first mate đặt, bạn chỉ đọc.

| Label | Ai đặt | Nghĩa |
| --- | --- | --- |
| `fm::todo` | người dùng | Giao issue này cho first mate. |
| `fm::human-replied` | người dùng | Tôi đã trả lời câu hỏi của first mate trong comment, làm tiếp đi. |
| `fm::accepted` | người dùng | Tôi duyệt kế hoạch, chạy đi. |
| `fm::triage` | first mate | Đã nhận, đang phân loại và lập kế hoạch. |
| `fm::plan-review` | first mate | Issue lớn, kế hoạch đã đăng, đang chờ bạn duyệt. |
| `fm::needs-human` | first mate | Đang dừng, cần bạn trả lời hoặc quyết định. |
| `fm::done` | first mate | Mọi merge request đã merged, mời bạn kiểm tra. |

Một issue chỉ nên mang một label trong bảng này tại một thời điểm.
Phía first mate điều đó luôn đúng: mỗi lần đặt label, [`bin/fm-gitlab-issue.sh`](../bin/fm-gitlab-issue.sh) gỡ mọi label `fm::` khác trong cùng một request, nên nó không bao giờ để lại hai trạng thái.
Phía bạn thì tùy gói GitLab của instance: scoped label là tính năng Premium trở lên, nên trên gói đó gắn `fm::human-replied` sẽ tự gỡ `fm::needs-human`.
Trên một instance Free thì không có cơ chế đó và nâng phiên bản cũng không đổi được điều này, cách đúng là gỡ label cũ bằng tay khi gắn label mới.
Lý do cần giữ đúng một label là poll hỏi từng label riêng, nên một issue mang hai label giao việc sẽ được nhận hai lần.

Đường đi thường gặp: bạn gắn `fm::todo`, first mate chuyển sang `fm::triage`, làm việc, rồi kết thúc ở `fm::done`.
Khi cần hỏi bạn, first mate chuyển sang `fm::needs-human` và dừng lại cho tới khi bạn gắn `fm::human-replied`.

## Cách đọc comment của first mate

First mate chỉ đăng ba loại comment và không bao giờ comment tiến độ.
Nếu bạn thấy một issue im lặng nhiều giờ, đó là bình thường: im lặng nghĩa là đang chạy và chưa có gì cần bạn.

**Comment phân loại và kế hoạch.**
Đăng một lần khi nhận việc.
Nó nêu loại issue (`bug`, `feature`, `chore`, `docs`, `question`), cỡ (`S`, `M`, `L`), làm theo hướng `ship` (ra merge request) hay `scout` (chỉ điều tra), mức kiểm định (delivery mode) sẽ áp dụng là `no-mistakes` hoặc `direct-PR`, kèm một checklist các việc con.
Với project được đăng ký ở mức `no-mistakes-prod-only`, first mate phân loại bề mặt của từng việc, nên comment nêu giá trị đã phân loại chứ không nêu tên mức đăng ký.
Mỗi việc con được chia nhỏ để làm trong khoảng 2 đến 5 phút và ra một merge request nhỏ, đủ để bạn đọc hết trong một lượt review.

Comment này không bị thay bằng comment mới khi có tiến triển: first mate sửa tại chỗ chính comment đó.
Một dòng checklist đã xong trông như sau:

```
- [x] 3/5 Tách hàm validate ra khỏi handler → !412 (merged)
```

Nên muốn biết việc đến đâu, hãy đọc lại comment kế hoạch chứ đừng tìm comment mới nhất.

**Comment cần người trả lời.**
Một câu hỏi rõ ràng, tối đa ba lựa chọn đánh dấu (a) (b) (c), và first mate luôn đề xuất đúng một lựa chọn kèm lý do.
Bạn trả lời bằng một comment, rồi gắn `fm::human-replied`.
Chỉ comment thôi thì first mate không chạy tiếp: label mới là tín hiệu.

**Comment tổng kết.**
Đăng khi mọi merge request của issue đã merged, liệt kê link các merge request, kèm label `fm::done`.

## Ai merge, ai đóng issue

Bạn merge từng merge request.
First mate không tự merge trong luồng này, với điều kiện project đã được đăng ký với `yolo` tắt như bước 1 của mục "Thêm project mới vào group" yêu cầu.
Đó là một yêu cầu mà việc đăng ký phải thỏa mãn chứ không phải một bảo đảm có sẵn: project nào được đăng ký với `yolo` bật thì first mate được quyền tự merge việc xanh của project đó, và tiêu chí người thật merge từng merge request sẽ lặng lẽ không còn đúng.

First mate cũng **không** đóng issue.
Nó chỉ gắn `fm::done`; bạn kiểm tra kết quả rồi tự đóng issue.
Ranh giới này là cố ý: đóng issue là xác nhận kết quả đúng ý bạn, và chỉ bạn xác nhận được điều đó.

## Issue lớn

Issue được phân loại cỡ `L` không chạy thẳng.
First mate đăng kế hoạch rồi dừng ở `fm::plan-review`.

Bạn có hai cách trả lời:

- Đồng ý: gắn `fm::accepted`, first mate bắt đầu làm.
- Muốn sửa kế hoạch: comment nêu chỗ cần đổi rồi gắn `fm::human-replied`, first mate sửa kế hoạch và đăng lại.

## Issue loại `question`

First mate không tự trả lời câu hỏi ra ngoài.
Nó soạn một bản nháp câu trả lời trong comment và gắn `fm::needs-human`.

Bạn đọc bản nháp, sửa nếu cần, rồi gắn `fm::human-replied`.
Khi đó first mate mới đăng bản chính thức.
Nghĩa là mọi câu trả lời cho người hỏi đều đã qua mắt bạn.

## Không có label từ chối

Bộ label không có trạng thái "từ chối", và đó là chủ ý.
Khi first mate cho rằng issue không nên làm, nó gắn `fm::needs-human` kèm một comment nêu khuyến nghị và lý do.
Quyết định cuối là của bạn: bạn đóng issue nếu đồng ý.

## Thêm project mới vào group

Thêm một project vào luồng không cần sửa code.

1. Clone project vào home đang chạy luồng này và đăng ký nó với mức kiểm định mặc định của bạn, một trong `no-mistakes`, `no-mistakes-prod-only` hoặc `direct-PR`, và phải để `yolo` tắt cho project đó.
   `yolo` tắt là điều kiện bắt buộc của luồng này, vì tiêu chí đã chốt là người thật merge từng merge request; `yolo` bật cho phép first mate tự merge và phá mất tiền đề đó.
   `no-mistakes-prod-only` là mức mặc định khi thêm một project có remote mà không nói gì thêm, nên đó là mức bạn gặp nhiều nhất ở bước này.
   Còn `local-only` không dùng được cho luồng này, vì nó làm việc trên nhánh local mà không cần remote và không ra merge request, trong khi tiền đề của trang này là mỗi việc con kết thúc bằng một merge request nhỏ do bạn merge.
   Tên các mức thuộc về [`bin/fm-project-mode.sh`](../bin/fm-project-mode.sh); nếu danh sách đó đổi thì đọc ở đó chứ không phải ở đây.
   Nhờ first mate làm bước này; nó có quy trình riêng cho việc thêm project.
2. Thêm đường dẫn project vào danh sách `projects` trong `config/gitlab-issues.json`.
   Viết tương đối so với group (`api-service`) hoặc viết đầy đủ (`<group>/api-service`) đều được.

Bỏ trống hoặc bỏ hẳn `projects` nghĩa là poll mọi project trong group và trong các subgroup.
Đó là lựa chọn tốt nếu bạn muốn mọi project mới tự động nằm trong luồng, nhưng khi đó bước clone và đăng ký ở trên vẫn phải làm.

Nếu một issue thuộc project chưa được clone và đăng ký, first mate không đoán: nó gắn `fm::needs-human` kèm lời nhắc rằng project chưa được đăng ký.

## Sự cố thường gặp

**Token bot hết hạn.**
Triệu chứng là poll báo lỗi thay vì im lặng, và không issue nào được nhận nữa.
Kiểm tra bằng `glab auth status --hostname <host>`, rồi đăng nhập lại bằng `glab auth login --hostname <host>`.
Poll chỉ báo cùng một lỗi một lần mỗi giờ chứ không báo mỗi vòng, nên bạn nhận một thông báo chứ không bị dội; nhịp đó thuộc về header của [`bin/fm-gitlab-issues.sh`](../bin/fm-gitlab-issues.sh).
Một vòng poll lỗi không làm mất dấu các issue đã thấy, nên sau khi token được sửa, các issue đang chờ vẫn được nhận đúng một lần.

**Project chưa được đăng ký.**
Issue bị gắn `fm::needs-human` với lời nhắc đăng ký.
Làm hai bước ở mục "Thêm project mới vào group", rồi gắn lại `fm::todo`.

**Cấu hình sai định dạng.**
Nếu file không phải JSON hợp lệ, `bin/fm-gitlab-issues.sh arm` từ chối và chỉ báo rằng file không phải JSON hợp lệ, không nêu trường nào.
Nếu file là JSON hợp lệ nhưng có giá trị sai, `arm` từ chối và nêu tên trường sai.

**Bạn gỡ hết label ngoài quy trình.**
Một issue không còn label `fm::` nào được hiểu là bạn đã rút việc đó lại.
Poll bỏ cặp (issue, label) đó khỏi sổ đã báo, nên nếu sau này bạn gắn label trở lại thì issue được nhận lại như mới thay vì bị bỏ qua.
Trước mỗi lần đổi label và trước khi đăng bất kỳ comment nào, first mate đọc lại tập label `fm::` của issue.
Thấy tập đó rỗng thì nó coi như bạn đã rút việc, dừng công việc đang làm dở, không đăng gì lên issue, và báo lại cho captain đúng một dòng.
Giới hạn thành thật của cách này là việc phát hiện xảy ra ở checkpoint kế tiếp chứ không tức thời, nên một việc con đang chạy có thể chạy xong trước khi công việc dừng lại.

## Phạm vi hiện tại

Hai script làm phần cơ khí của luồng: [`bin/fm-gitlab-issues.sh`](../bin/fm-gitlab-issues.sh) phát hiện và ghi lại, [`bin/fm-gitlab-issue.sh`](../bin/fm-gitlab-issue.sh) đọc và sửa một issue.
Phần còn lại của luồng, gồm phân loại, chia việc con, soạn ba loại comment và chuyển label theo đúng thứ tự, thuộc về skill `gitlab-issue-intake`, và không có script nào cưỡng chế nửa này của luồng.
Chừng nào skill `gitlab-issue-intake` chưa có trong checkout của bạn thì chỉ poll và helper thao tác issue là chạy được, còn nửa phía agent của luồng chưa hoạt động.
Nếu bạn thấy first mate đi lệch khỏi tài liệu này, đó là chỗ cần báo lại chứ không phải chỗ tự sửa bằng tay trên GitLab.

Việc theo dõi và merge merge request trên GitLab là một cơ chế riêng, đã có sẵn từ trước; xem [`docs/gitlab-merge-watch.md`](gitlab-merge-watch.md).
