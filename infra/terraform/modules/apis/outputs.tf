# Enabled API service names (post-apply).
output "enabled_services" {
  value = toset([for s in google_project_service.enabled : s.service])
}
