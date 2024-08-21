##Before you begin:
- choose your kubeconfig and import it
- create namespaces.txt file
- make sh executable via command bellow
```bash 
chmod +x dump_* 
```

##How must be your structure to use this scripts:

- root_dir/
  - dump_mongo.sh
  - dump_pg.sh
  - dump_redis.sh
  - dump_time.sh
  - namespaces.txt