# AWX on Kubernetes with ELK to create reports

I love Kubernetes and Ansible. Both are some of the [10 most popular Open Source projects in github in 2019](https://insights.dice.com/2019/11/08/10-popular-open-source-projects-github/). That is why I wanted to give it a try to deploy ansible awx in kubernetes, along with an ELK stack (Elasticsearch, Logstash and Kibana), to store playbook information and create some nice dashboards.

There are several ways to extract information from AWX. You can see some of them if you prefer the ELK stack in the following picture.

![Extracting informacion from AWX](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/extract_awx_data.svg)

We are exploring the solid line path, where awx sends through the external logger to ELK.

## Kubernetes Setup

A Solution Architect is like a Chef: selects the ingredients bearing in mind the final taste of the course. In this case, we need a base for our pizza, and kubernetes distribution is my favourite selection.

You can use whichever option you want, either managed or deployed by yourself. [Minikube](https://kubernetes.io/docs/tasks/tools/install-minikube/) or [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/) are easy choices if you have a decent laptop and don’t want to spend too much on a first try.

I redirect to those pages to setup a kubernetes cluster if you want that option, with an ingress controller and a wildcard A DNS record for the ingress. From now on, I will assume you have a fully functional cluster to deploy on top of it. I will use a minikube for sample values, with the [ingress plugin (nginx)](https://kubernetes.io/docs/tasks/access-application-cluster/ingress-minikube/#enable-the-ingress-controller) deployed on it. I also use dnsmasq to set up a wildcard domain for my minikube, but if you don’t know how to do it, I recommend using ingress-dns plugin.

## AWX

Before configuring AWX, we are creating a project folder on our minikube installation to store the temporary sample. The default playbook installation uses hostpath, if you want to use another different storage, skip the project_data_dir in the inventory, and add the volume later for /var/lib/awx/projects on the awx deployment. Log into minikube with `minikube ssh`, and then execute

```bash
sudo mkdir -p /var/lib/awx/projects/sample
sudo chmod 777 /var/lib/awx/projects/sample
```
To check everything is ok, inside minikube, execute the following:

```
touch /var/lib/awx/projects/sample/sample.txt
ls -lrt /var/lib/awx/projects/sample/sample.txt
```

And you should see the new created file on the samples folder. Exit minikube, as the following

__Warning__: That creates an all-user writable folder on minikube. It is only for testing purposes, that is not recommended __at all__ in a real cluster, as it is a security breach.

Now, clone the repo https://github.com/ansible/awx/, or download a release from https://github.com/ansible/awx/releases/. Go to the installer folder, where there is a playbook for installing awx on kubernetes or openshift. 

Then, you will have to setup different values. The only needed to be changed is, kubernetes_context. If you don’t know the cluster context, you can run kubectl config get-contexts to list them, or use kubectl config current-context to know your current one. 

```properties
kubernetes_context=minikube
```

You can go through all of them (some are for kubernetes, some for openshift and some for docker-compose). For example, the postgresql pg_volume_capacity, that defines volume capacity in GB.

```properties
pg_volume_capacity=1
```

Additionally, as we will run a sample playbook, instead of using a git repo, we will store directly the repo locally, so we uncomment

```properties
project_data_dir=/var/lib/awx/projects
```

And last but not least, I will setup the ingress hostname/annotations to set up the access to awx management console. In my case, I am using dnsmasq

```properties
kubernetes_ingress_hostname=awx.minikube.cloud
```

Once the values are set, it is just to execute the ansible playbook to install awx:

```bash
ansible-playbook -i inventory install.yaml
```

After some time, you will have an awx instance up and running, to check it works, connect to the `<kubernetes_ingress_hostname>` with `<admin_user>/<admin_password>` credentials defined on your inventory.

## ELK

To deploy ELK stack on your kubernetes cluster, we will use the official helm charts from https://github.com/elastic/helm-charts. we clone that repository locally. 

### Elasticsearch

For elasticsearch, let’s just reduce the number of replicas and storage to fit in an small testing environment. Our custom values.yaml could be:

```yml
replicas: 1
minimumMasterNodes: 1

esConfig:
  elasticsearch.yml: |
    node.store.allow_mmap: false

volumeClaimTemplate:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 2Gi

ingress:
  enabled: true
  annotations: 
    kubernetes.io/ingress.class: nginx
  path: /
  hosts:
    - elasticsearch.minikube.cloud

sysctlInitContainer:
  enabled: false
```

Now, we can deploy our elasticsearch:

```bash
helm install elasticsearch <helm-charts>/elasticsearch -f values.yaml -n awx
```

After some time, if everything is ok, calling the ingress for elasticsearch you should get something like:

```json
{
  "name" : "elasticsearch-master-0",
  "cluster_name" : "elasticsearch",
  "cluster_uuid" : "qsz8ZKXcTBKf5QZE5ZHyew",
  "version" : {
    "number" : "7.6.2",
    "build_flavor" : "default",
    "build_type" : "docker",
    "build_hash" : "ef48eb35cf30adf4db14086e8aabd07ef6fb113f",
    "build_date" : "2020-03-26T06:34:37.794943Z",
    "build_snapshot" : false,
    "lucene_version" : "8.4.0",
    "minimum_wire_compatibility_version" : "6.8.0",
    "minimum_index_compatibility_version" : "6.0.0-beta1"
  },
  "tagline" : "You Know, for Search"
}
```

### Kibana

We can install helm chart with the same approach as elasticsearch. I will only adapt the ingress hostname:

```yml
ingress:
  enabled: true
  annotations: 
    kubernetes.io/ingress.class: nginx
  path: /
  hosts:
    - kibana.minikube.cloud
```

As before we execute:

```bash
helm install kibana <helm-charts>/kibana  -f values.yaml -n awx
```

After that, when kibana pod is healthy, we can see the initial screen.

![Kibana Start Page](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/kibana_startup.png)

### Logstash

We will use the same approach (helm) done with elasticsearch and kibana. We need to define the logstash pipeline that receives the messages and store them in elasticsearch.

```yml
logstashConfig: 
  logstash.yml: |
    http.host: 0.0.0.0
    xpack.monitoring.enabled: false

logstashPipeline: 
  logstash.conf: |
    input {
      http {}
    }
    filter {
      json {
        source => "message"
      }
    }
    output { 
      elasticsearch { 
        hosts => ["http://elasticsearch-master:9200"] 
        index => "awx" 
      } 
    }

service: 
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      protocol: TCP
      targetPort: 8080

```

And then:

```bash
helm install logstash ~/git/helm-charts/logstash -f values.yaml -n awx
```

Once the pod is ready, we can now configure awx to use the external logging.

## Configuring logstash external logger in AWX

The configuration if fairly simple, and [described in the product version of awx, ansible tower](https://docs.ansible.com/ansible-tower/latest/html/administration/logging.html). We will setup the logstash service, host http[]()://logstash-logstash, port 8080. There are five different loggers, for this example I will select job_events which tracks tasks in a job. I will also check log system tracking facts individually, so if a task is executed on several hosts, we will receive a log per host and not an aggregated one.

![AWX System/Settings: Logging](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/awx_logging.png)

Click on test, and if everything is ok, you will receive a success, and then you can save the configuration.

## Create a simple job template example

We are going to create a simple job template that collects hardware information of one linux host and presents it in a view.

In our case, We are using the minikube instance, but you can use other linux (just for this example, ansible can query windows, networking equipment, etc). I run:

First, I create a sample inventory.

![AWX Inventory/new inventory](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/awx_new_inventory.png)

Then, I need to know which ip my minikube is configured with. I execute: 

```bash
minikube ip
```

And get 172.17.0.2. That is the host address I will add to my inventory.

![AWX Inventory/new host](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/awx_inventory_new_host.png)

Then, you need to create the credentials. If you use the default profile on minikube, that credentials are placed on .minikube/machines/minikube/id_rsa.

So in credentials, first we select "machine" credentials type, which allows to set up a private ssh connection key.

![AWX Credentials/machine](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/awx_credentials_machine.png)

And we fill the ssh key included in the previous id_rsa file.

![AWX Credentials/new credential](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/awx_new_credential.png)

We have to set up a new playbook for the job. The best practices suggests to store this playbook on a git repository, but for our test purposes, we will directly store it in the ephemeral filesystem. We are entering the pod to do so:

```bash
kubectl -it exec $(kubectl get pods -l app=awx -n awx -o name) -c awx-web -n awx -- /bin/bash
```

On the container, we create a sample playbook (in ephemeral storage) with the following command:

```bash
cat > /var/lib/awx/projects/sample/main.yaml << _EOF_
- name: minikube_hardware
  hosts: all
  order: sorted
  remote_user: core
  gather_facts: False
  tasks:
  - name: Collect only facts returned by hardware
    setup:
      gather_subset:
        - '!all'
        - '!any'
        - hardware
      filter: "ansible_processor*"
_EOF_
```

Then we select the demo project, and changes the git project source for manual, with the sample folder created before.

![AWX Projects/demo project](/images/2020-05_AWX_on_Kubernetes_with_ELK_to_create_reports/awx_project.png)

## Create a simple query & view in kibana

## Notes
1. AWX has moved to a syslog omhttp buffer-based remote sender on https://github.com/ansible/awx/pull/6108. Before that PR, the implementation was a fire & forget direct http connection to logstash.

2. Ansible message is parsed in logstash as a json tree. Json can include fields with invalid names, (like “hostvars[inventory_hostname]”), that message will throw an exception at logstash and will only send the other fields in the message (like job number, etc).

3. Some facts or custom-made messages can introduce fields, that even being valid on json format, are not valid for elasticsearch auto-indexing. An [example](https://discuss.elastic.co/t/storing-ansible-facts-in-elasticsearch-json-mapper-parsing-exception/68053/2) shown here, happens for example with version_info in python facts, that sometimes is like 

   "version_info": [ 3, 6, 8, "final", 0 ]

   Which is not valid for elastic, mixing long and string values. A good approach is pre-creating the index, with mapping rules that fixes those type issues.
