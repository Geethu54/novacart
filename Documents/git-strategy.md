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

test


testinggg
