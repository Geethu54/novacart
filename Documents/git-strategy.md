Using one branch Main 

Short lived branches - feat , hotfix 
-------------

Every change to Main branch is enforced using a PR (PR is required to push change to main branch)

----------
naming convention of Branches

- use Feat-xxxx (feat- ticketnumber )
- use hfix-XXX(for hotfix ue the incident number )

---------

in order to get the PR merged we will have few readiness checks
1) Peer review
2) CI checks (ensures the application is working with the new changes )
3) any security scanners (SYNK or CheckMarx)

--------------
trade OFF 
if fornt end team is different from back end we might end up with lot of merge conflicts and one should wait for other to commit together .
in this scenario best approach i believe is to split the repo in to 2 repos fornt end and backend (else have a new branch may be developemt and sync changes ) only completed run will be pushed to main (this will be achieved during CI checks to Main branch PR)

test -2

 git push
Enumerating objects: 7, done.
Counting objects: 100% (7/7), done.
Delta compression using up to 10 threads
Compressing objects: 100% (4/4), done.
Writing objects: 100% (4/4), 349 bytes | 349.00 KiB/s, done.
Total 4 (delta 3), reused 0 (delta 0), pack-reused 0 (from 0)
remote: Resolving deltas: 100% (3/3), completed with 3 local objects.
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: Review all repository rules at https://github.com/Geethu54/novacart/rules?ref=refs%2Fheads%2Fmain
remote: 
remote: - Changes must be made through a pull request.
remote: 
To https://github.com/Geethu54/novacart.git
 ! [remote rejected] main -> main (push declined due to repository rule violations)
error: failed to push some refs to 'https://github.com/Geethu54/novacart.git'



test
