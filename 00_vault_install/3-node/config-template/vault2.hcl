ui            = true
disable_mlock = true

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-2" # change-me

  retry_join {
    leader_api_addr = "http://13.251.124.180:8200" # change-me
  }
  retry_join {
    leader_api_addr = "http://13.212.227.50:8200" # change-me
  }
  retry_join {
    leader_api_addr = "http://18.138.224.190:8200" # change-me
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://13.212.227.50:8200" # change-me
cluster_addr = "http://13.212.227.50:8201" # change-me