output "enabled_services" {
  value = toset([for s in google_project_service.enabled : s.service])
}
