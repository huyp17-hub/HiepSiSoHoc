// =====================================================================
//  CẤU HÌNH MÁY CHỦ CHO HIỆP SĨ SỐ HỌC
//  Khóa publishable được thiết kế để nằm công khai trong trang web;
//  dữ liệu vẫn an toàn nhờ các quy tắc bảo mật trong schema.sql.
//  TUYỆT ĐỐI KHÔNG dán khóa secret (sb_secret_...) hay service_role vào đây.
// =====================================================================
window.BACKEND = {
  url: "https://fsdohajkvjeyzsvsidpe.supabase.co",
  anonKey: "sb_publishable_CysTwG7-jzTqxVECCgQA2g_5SspT_gD"
};