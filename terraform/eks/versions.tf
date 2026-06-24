terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }

    # helm provider 目前最高为 2.x，没有 3.x 发布
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }

    # kubernetes provider 目前最高为 2.x，没有 3.x 发布
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }

    # 用来 apply root-application.yaml 的轻量 provider
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}
