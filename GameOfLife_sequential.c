/** \file
*/
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <limits.h>

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
    sprintf(newfilename, "table%dx%d_new.bin", N, N);
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

/**
 * play - Plays the game for one step.
 * First, counts the neighbors, taking into account boundary conditions
 * Then, acts on the rules.
 * Updates need to happen all together, so a temporary new array is allocated
 */
void play(int *X, int N){
    int i = 0, j = 0;
    int *new;
    if (! ( new = (int *)malloc(N*N*sizeof(int))) )
        die("Memory allocation failed");
    int births = 0, deaths = 0, ok = 0;
    int up, down, left, right;

    for(i=0; i<N;i++){
        for(j=0;j<N;j++){
            //by using unsigned variables, we force the index to overflow
            //by taking the following modulo, we convert the potenital negative
            //value of i-1 into N and the potential greater than N value to 0

            up = ((i-1)+N)%N;
            down = (i+1)%N;
            left = ((j-1)+N)%N;
            right = (j+1)%N;
            int sum =
                X[N*up+left]+   //i-1, j-1
                X[N*up+j]+    //i-1, j
                X[N*up+right]+ //i-1, j+1

                X[N*i+left]+      //i, j-1
                X[N*i+right]+    //i, j+1

                X[N*down+left]+  //i+1, j-1
                X[N*down+j]+   //i+1, j
                X[N*down+right];//i+1, j+1

            //act based on rules
            if(X[i*N+j] == 0 /*dead*/ && sum == 3 /*birth*/){
                new[i*N+j]=1; //born
                births++;
            }else if ( X[i*N+j] == 1 /*alive*/ && (sum < 2 /*loneliness*/ || sum>3 /*overpopulation*/) ){
                new[i*N+j]=0; //dies
                deaths++;
            }else{
                new[i*N+j] = X[i*N+j]; //nothing changes
                ok++;
            }
        }
    }


    //copy board
    for (i=0; i<N; i++){
        for(j=0; j<N; j++){
            X[i*N+j] = new[i*N+j];
        }
    }

    //testing
    if(deaths+births+ok != N*N)
        warn("Testing issue - not all cells were taken into account");

    //cleanup and return
    free(new);
    return;
}


void printCells(int *table, int N){
    int j=0, i=0;
    for(i=0; i<4; i++){
        for(j=0; j<4; j++){
            printf("%d ", table[N*i+j]);
        }
        printf("\n");
    }
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
    struct timeval startwtime, endwtime;

    //read input
    read_from_file(table, filename, N);
    printCells(table, N);

    //play game for t generations
    printf("Generation \t Time\n");
    for(gen=0; gen<t; gen++){

        gettimeofday(&startwtime, NULL);
        play(table, N);
        gettimeofday(&endwtime, NULL);

        double time = (double)((endwtime.tv_usec - startwtime.tv_usec)/1.0e6 + endwtime.tv_sec - startwtime.tv_sec);
        printf("[%d]\t\t %fs\n", gen, time);
    }

    //save output for later
    printCells(table, N);
    write_to_file(table, filename, N);

    free(table);
    return 0;
}
