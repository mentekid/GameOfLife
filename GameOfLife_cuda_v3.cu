
/** \file
*/
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <stdint.h>

#define BLOCKLEN 512

int nextPower(int);
void die(const char *);
void warn(const char *);
void read_from_file(int *, char *, int);
void write_to_file(int *, char *, int);

/**
 * play - Plays the game for one step.
 * First, counts the neighbors, taking into account boundary conditions
 * Then, acts on the rules.
 * Updates need to happen all together, so a temporary new array is allocated
 */
__global__ void play(int *X, int *d_new, int N){
    //a block of threads works on a row
    int glob_i = blockIdx.x; //which row
    int temp_i = glob_i;

    //shared memory size = 3 lines * N cells each
    extern __shared__ int localArray[];

    //read row above (i-1) and write to localArray[0][j]
    if (glob_i == 0){
        temp_i = N - 1; //cyclic boundary condition
    }else{
        temp_i = glob_i - 1; //simple case
    }
    for(int j = threadIdx.x; j < N; j+=blockDim.x){
        if(j<N){
            localArray[0*N + j] = X[(temp_i)*N + j];
        }
    }

    //read own row (i) and write to localArray[1][j]
    for(int j = threadIdx.x; j < N; j+=blockDim.x){
        if(j<N){
            localArray[1*N + j] = X[(glob_i)*N + j];
        }
    }

    //read from row below (i+1) and write to localArray[2][j]
    if(glob_i == N-1){
        temp_i = 0; //cyclic boundary condition
    }else{
        temp_i = glob_i + 1; //simple case
    }
    for(int j = threadIdx.x; j < N; j+=blockDim.x){
        if(j<N){
            localArray[2*N + j] = X[(temp_i)*N + j];
        }
    }
    //wait for shared memory to be "full"
    __syncthreads();

    //shared memory is now complete, we're ready to operate on it
    int up, down, left, right;
    for(int j = threadIdx.x; j < N; j+=blockDim.x){
        if (j < N){
            int idx = N*glob_i + j;

            up = 0;
            down = 2;
            //cyclic boundary conditions
            left =  j == 0 ? N - 1 : j - 1;
            right = j == N-1 ? 0 : j + 1; 

            int sum = 
                localArray[N*up+left]+       //i-1, j-1
                localArray[N*up+j]+          //i-1, j
                localArray[N*up+right]+      //i-1, j+1

                localArray[N*1+left]+        //i, j-1
                localArray[N*1+right]+       //i, j+1

                localArray[N*down+left]+     //i+1, j-1
                localArray[N*down+j]+        //i+1, j
                localArray[N*down+right];    //i+1, j+1

            
            //act based on rules - write to global array
            if(localArray[1*N + j] == 0  && sum == 3 ){
                d_new[idx]=1; //born
            }else if ( localArray[1*N + j] == 1  && (sum < 2 || sum>3 ) ){
                d_new[idx]=0; //dies - loneliness or overpopulation
            }else{
                d_new[idx] = localArray[1*N + j]; //nothing changes
            }
        }
    }
    return;
}

/**
 * main - plays the game of life for t steps according to the rules:
 * - A dead(0) cell with exactly 3 living neighbors becomes alive (birth)
 * - A dead(0) cell with any other number of neighbors stays dead (barren)
 * - A live(1) cell with 0 or 1 living neighbors dies (loneliness)
 * - A live(1) cell with 4 or more living neighbors dies (overpopulation)
 * - A live(1) cell with 2 or 3 living neighbors stays alive (survival)
 */
int main(int argc, char **argv){

    //sanity check for input
    if(argc !=4){
        printf("Usage: %s filename size t, where:\n", argv[0]);
        printf("\tfilename is the input file \n");
        printf("\tsize is the grid side and \n");
        printf("\tt generations to play\n");
        die("Wrong arguments");
    }

    //declarations
    char *filename = argv[1];
    int N = atoi(argv[2]);
    int t = atoi(argv[3]);
    int gen = 0;
    int *table = (int *)malloc(N*N*sizeof(int));
    if (!table)
        die("Couldn't allocate memory to table");

    //CUDA - divide the table in N blocks of 1 line, 512 threads per block
    dim3 threadsPerBlock(BLOCKLEN, 1); //max threads/block
    dim3 numBlocks(N, 1); //split board into blocks

    //CUDA - timing
    float gputime;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    //read input
    read_from_file(table, filename, N);

    //CUDA - copy to device
    int *d_table;
    cudaMalloc(&d_table, N*N*sizeof(int));
    int *d_new;
    cudaMalloc(&d_new, N*N*sizeof(int));
    cudaEventRecord(start, 0);
    cudaMemcpy(d_table, table, N*N*sizeof(int), cudaMemcpyHostToDevice);

    //play game for t generations
    for(gen=0; gen<t; gen++){

        //alternate between using d_table and d_new as temp
        if(gen%2==0){
            //3*N*sizeof(int): size for shared memory
            play<<<numBlocks, threadsPerBlock, 3*N*sizeof(int)>>>(d_table /*data*/, d_new /*temp*/, N);
        }else{
            play<<<numBlocks, threadsPerBlock, 3*N*sizeof(int)>>>(d_new /*data*/, d_table /*temp*/, N);
        }
        cudaDeviceSynchronize(); //don't continue if kernel not done

    }
    cudaEventRecord(stop, 0);

    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&gputime, start, stop);
    printf("[%d]\t %g \n",gen, gputime/1000.0f);

    //copy back from device
    if(t%2==1){
        cudaMemcpy(table, d_new, N*N*sizeof(int), cudaMemcpyDeviceToHost);
    }else{
        cudaMemcpy(table, d_table, N*N*sizeof(int), cudaMemcpyDeviceToHost);
    }
    //save output for later
    write_to_file(table, filename, N);

    free(table);
    cudaFree(d_new);
    cudaFree(d_table);
    return 0;
}

/**
 * die - display an error and terminate.
 * Used when some fatal error happens
 * and continuing would mess things up.
 */
void die(const char *message){
    if(errno){
        perror(message);
    }else{
        printf("Error: %s\n", message);
    }
    exit(1);
}

/**
 * warn - display a warning and continue
 * used when something didn't go as expected
 */
void warn(const char *message){
    if(errno){
        perror(message);
    }else{
        printf("Warning: %s\n", message);
    }
    return;
}

/**
 * read_from_file - read N*N integer values from an appropriate file.
 * Saves the game's board into array X for use by other functions
 * Warns or kills the program if something goes wrong
 */
void read_from_file(int *X, char *filename, int N){

    FILE *fp = fopen(filename, "r+");
    int size = fread(X, sizeof(int), N*N, fp);
    if(!fp)
        die("Couldn't open file to read");
    if(!size)
        die("Couldn't read from file");
    if(N*N != size)
        warn("Expected to read different number of elements");

    printf("elements read: %d\n", size);

    fclose(fp);
    return;
}

/**
 * write_to_file - write N*N integer values to a binary file.
 * Saves game's board from array X to the file
 * Names the file tableNxN_new.bin, so the input file is not overwritten
 */
void write_to_file(int *X, char *filename, int N){

    //save as tableNxN_new.bin
    char newfilename[100];
    sprintf(newfilename, "cuda_table%dx%d.bin", N, N);
    printf("writing to: %s\n", newfilename);

    FILE *fp;
    int size;
    if( ! ( fp = fopen(newfilename, "w+") ) )
        die("Couldn't open file to write");
    if( ! (size = fwrite(X, sizeof(int), N*N, fp)) )
        die("Couldn't write to file");
    if (size != N*N)
        warn("Expected to write different number of elements");

    fclose(fp);
    return;
}

int nextPower(int N){
    int n=0;
    while(1){
        if(1<<n < N){
            n++;
        }else{
            return 1<<n;
        }
    }
}
