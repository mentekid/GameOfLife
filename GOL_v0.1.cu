/** \file
*/
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <stdint.h>

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
    int i = (blockIdx.x*blockDim.x)+threadIdx.x;
    int j = (blockIdx.y*blockDim.y)+threadIdx.y;
    int up, down, left, right;

        if( i<N && j<N){

            int sum = 0;
            // Code below is faster but hard to read
            up = ((i-1)+N)%N;
            down = (i+1)%N;
            left = ((j-1)+N)%N;
            right = (j+1)%N;
            sum =
                X[N*up+left]+   //i-1, j-1
                X[N*up+j]+    //i-1, j
                X[N*up+right]+ //i-1, j+1

                X[N*i+left]+      //i, j-1
                X[N*i+right]+    //i, j+1

                X[N*down+left]+  //i+1, j-1
                X[N*down+j]+   //i+1, j
                X[N*down+right];//i+1, j+1


            //act based on rules
            if(X[i*N+j] == 0  && sum == 3 ){
                d_new[i*N+j]=1; //born
            }else if ( X[i*N+j] == 1  && (sum < 2 || sum>3 ) ){
                d_new[i*N+j]=0; //dies - loneliness or overpopulation
            }else{
                d_new[i*N+j] = X[i*N+j]; //nothing changes
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
    if(argc !=5){
        printf("Usage: %s filename size t threads, where:\n", argv[0]);
        printf("\tfilename is the input file \n");
        printf("\tsize is the grid side and \n");
        printf("\tt generations to play\n");
        printf("\t threadsXthreads per block\n");
        die("Wrong arguments");
    }

    //declarations
    char *filename = argv[1];
    int N = atoi(argv[2]);
    int t = atoi(argv[3]);
    int thrds = atoi(argv[4]);
    int gen = 0;
    int *table = (int *)malloc(N*N*sizeof(int));
    if (!table)
        die("Couldn't allocate memory to table");

    //read input
    read_from_file(table, filename, N);

    //get the smallest power of 2 larger than N
    int Npow2 = nextPower(N);

    //CUDA - timing
    float gputime;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    
    //CUDA - split board into squares 
    dim3 threadsPerBlock(thrds, thrds);
    dim3 numBlocks(Npow2/threadsPerBlock.x, Npow2/threadsPerBlock.y);

    //CUDA - copy input to device
    int *d_table;
    cudaMalloc(&d_table, N*N*sizeof(int));
    int *d_new;
    cudaMalloc(&d_new, N*N*sizeof(int));
    cudaMemcpy(d_table, table, N*N*sizeof(int), cudaMemcpyHostToDevice);

    //CUDA - play game for t generations
    cudaEventRecord(start, 0);
    for(gen=0; gen<t; gen++){
        //alternate between using d_table and d_new as temp
        if(gen%2==0){
            play<<<numBlocks, threadsPerBlock>>>(d_table /*data*/, d_new /*temp*/, N);
        }else{
            play<<<numBlocks, threadsPerBlock>>>(d_new /*data*/, d_table /*temp*/, N);
        }
        cudaDeviceSynchronize(); //don't continue if kernel not done
    }

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&gputime, start, stop);
    printf("[%d]\t %g \n",gen, gputime/1000.0f);

    //CUDA - copy data from device
    if(t%2==1){
        cudaMemcpy(table, d_new, N*N*sizeof(int), cudaMemcpyDeviceToHost);
    }else{
        cudaMemcpy(table, d_table, N*N*sizeof(int), cudaMemcpyDeviceToHost);
    }
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

/**
 * nextPower - return smallest power of 2 larger than N
 */
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
