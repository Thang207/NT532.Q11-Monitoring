output "key_name" {
  value       = aws_key_pair.this.key_name
  description = "Tên keypair đã tạo trên AWS"
}

output "private_key_path" {
  value       = local_file.private_key_pem.filename
  description = "Đường dẫn file .pem (đã chmod 0600)"
}

output "master_public_ip" {
  value       = aws_instance.master.public_ip
  description = "Public IP của master"
}

output "worker_public_ips" {
  value       = [for w in aws_instance.worker : w.public_ip]
  description = "Danh sách Public IP của các worker"
}

output "ssh_example_master" {
  value       = "ssh -i ${local_file.private_key_pem.filename} ubuntu@${aws_instance.master.public_ip}"
  description = "Lệnh SSH ví dụ vào master"
}

output "ssh_example_worker_1" {
  value       = length(aws_instance.worker) > 0 ? "ssh -i ${local_file.private_key_pem.filename} ubuntu@${aws_instance.worker[0].public_ip}" : ""
  description = "Lệnh SSH ví dụ vào worker-1"
}
