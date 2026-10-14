# Your Istio configuration goes here

Put every Istio resource you write for the exam in this folder, numbered in
apply order, for example:

    00-peerauthentication.yaml
    10-authz-deny-all.yaml
    11-authz-allow-gateway.yaml
    20-catalog-canary.yaml
    ...

The grader will run exactly:

    kubectl apply -f istio/

so everything must apply cleanly on a fresh cluster where MeshMart and
Istio are already installed. (This README is ignored by kubectl - it only
picks up .yaml, .yml and .json files.)
