output "cluster_arn" {
  description = " ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = " Endpoint of the EKS cluster Kubernetes API server"
  value       = module.eks.cluster_endpoint
}


output "cluster_name" {
  description = " Name of the EKS cluster"
  value       = module.eks.cluster_name
}
