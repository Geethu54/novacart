CI design 

created a github workflow for validation checks 

3 satges 
 
1) validation checks - checks the syntax erros on both frontend and backend. also checks whether the required packages are being installed cleanly.
this includes repo check for any secrets leaks 
2) actual code tests - this step actually checks if the tests are passing written by the Dev teams
3) validation of docker builds - this steps checks if the docker builds are sucessfull just running docker build command to make sure the image build is successfull 

So adding ON statement which makes this triggers on every pull request to the Main branch 

