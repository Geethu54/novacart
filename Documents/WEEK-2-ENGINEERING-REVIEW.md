what is currently working 
End to END appliacation hsoted on azure using terrafrom .
what the environment is ready for
Dev environment
what it is not ready for yet
teraaform backend , automation (cd)
the strongest parts of the design
seperate subnets (public and private to protect our DB and backend ) , used reverse proxy to safegaurd backend .
the remaining risks
the tfsate file is not stored correctly still in local no centralized location
the controls you would still want before production
bakend for terrafrom state file , location to store screts , security group rules .
any assumptions you made during review
nothing .

biggest risks - not ready for continuous deployment, secrets are passed as command line variables to tf vars ,no proper security group rules even though saved from public networks but still has risk if new instance other than novacart frontend launched in network could access database .