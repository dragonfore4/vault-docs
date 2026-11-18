 vault read sys/locked-users
Key             Value
---             -----
by_namespace    [map[counts:1 mount_accessors:[map[alias_identifiers:[f3807113-515d-c6fa-aa60-549fc8a761d6] counts:1 mount_accessor:auth_approle_54b48bd5]] namespace_id:root namespace_path:]]
total           1

vault write -f sys/locked-users/<mount_accessor>/unlock/<alias_identifiers>

vault write -f sys/locked-users/auth_approle_54b48bd5/unlock/f3807113-515d-c6fa-aa60-549fc8a761d6

vault read sys/locked-users


// test secret_id able to use
vault write auth/approle/login role_id=f3807113-515d-c6fa-aa60-549fc8a761d6 secret_id=<secret_id ใหม่>
