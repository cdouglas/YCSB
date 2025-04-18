package site.ycsb.db;

import org.apache.commons.io.output.NullOutputStream;
import org.apache.curator.shaded.com.google.common.io.ByteStreams;
import org.apache.iceberg.CatalogProperties;
import org.apache.iceberg.io.AtomicOutputFile;
import org.apache.iceberg.io.CAS;
import org.apache.iceberg.io.InputFile;
import org.apache.iceberg.io.SupportsAtomicOperations;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.Vector;
import java.util.concurrent.TimeUnit;

public class FileIOClient extends DB {

  private static final Logger logger = LoggerFactory.getLogger(FileIOClient.class);

  private static final String FILEIO_STORE = "fileio.store";
  private static final String MAX_ATTEMPTS = "fileio.max.attempts";
  private static final String FILE_SIZE = "fileio.file.size";
  private static final String MAX_LOG_SIZE = "fileio.max.log.size";
  private static final String DELTA_SIZE = "fileio.delta.size";
  private static final String FILE_NAME = "fileio.file.name";
  private static final String DEBUG_THREADS = "fileio.debug.threads"; // separate object per thread

  private static boolean inited = false;

  String sacriFile;
  int baseSize;
  int deltaSize;
  int maxFileSize;
  int maxAttempts;
  SupportsAtomicOperations<CAS> fileIO;
  byte[] replScratch;
  byte[] deltaScratch;
  final Random rand = new Random();

  @Override
  public void init() throws DBException {
    baseSize = Integer.parseInt(getProperties().getOrDefault(FILE_SIZE, Integer.toString(1 << 14)).toString());
    maxFileSize = baseSize + Integer.parseInt(getProperties().getOrDefault(MAX_LOG_SIZE, Integer.toString(1 << 24)).toString());
    deltaSize = Integer.parseInt(getProperties().getOrDefault(DELTA_SIZE, Integer.toString(1 << 8)).toString());
    maxAttempts = Integer.parseInt(getProperties().getOrDefault(MAX_ATTEMPTS, Integer.toString(10)).toString());
    replScratch = new byte[baseSize];
    deltaScratch = new byte[deltaSize];
    String bucket = getProperties().getOrDefault(FileIOCatalogClient.BUCKET_NAME, CatalogClient.YCSB_BUCKET).toString();
    boolean debugThread = Boolean.parseBoolean(getProperties().getOrDefault(DEBUG_THREADS, "false").toString());
    try {
      final Map<String, String> properties = new HashMap<>();
      Object o = getProperties().get(FILEIO_STORE);
      if ("aws".equals(o)) {
        // TODO hack for testing, plumb this correctly
        bucket = "lst-pbafvfgrapl--usw2-az3--x-s3"; // s3 express bucket
        fileIO = FileIOCatalogClient.s3FileIO(bucket, properties);
        System.out.println("### S3 DIRECT ###");
      } else if ("gcp".equals(o)) {
        fileIO = FileIOCatalogClient.gcsFileIO(bucket, properties);
        maxFileSize = 0; // force CAS
        System.out.println("### GCS DIRECT ###");
      } else if ("azure".equals(o)) {
        fileIO = FileIOCatalogClient.azureFileIO(bucket, properties);
        System.out.println("### AZURE DIRECT ###");
      } else {
        throw new IllegalArgumentException("Unknown fileio object: " + getProperties().get(FILEIO_STORE));
      }
      sacriFile = getProperties().getOrDefault(FILE_NAME,
          properties.get(CatalogProperties.WAREHOUSE_LOCATION) + "/" + "sacriFile").toString();
      if (debugThread) {
        sacriFile += "-" + Thread.currentThread().getId();
      }
      System.out.println("### " + sacriFile + " ###");
      synchronized (FileIOClient.class) {
        if (!inited) {
          InputFile in = fileIO.newInputFile(sacriFile);
          AtomicOutputFile<CAS> out = fileIO.newOutputFile(in);
          rand.nextBytes(replScratch);
          atomicOp(out, replScratch, AtomicOutputFile.Strategy.CAS);
          System.out.println("Created: " + sacriFile);
          inited = true;
        }
      }
    } catch (Exception e){
      throw new DBException("Failed to load remote / init storage", e);
    }
  }

  @Override
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
    InputFile in = fileIO.newInputFile(sacriFile);
    try (InputStream i = in.newStream();
         NullOutputStream n = NullOutputStream.NULL_OUTPUT_STREAM) {
      ByteStreams.copy(i, n);
    } catch (IOException e) {
      return Status.ERROR;
    }
    return Status.OK;
  }

  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields, Vector<HashMap<String, ByteIterator>> result) {
    return Status.NOT_IMPLEMENTED;
  }

  // from BaseTransaction
  // default 4 retries
  //           .exponentialBackoff(
  //              base.propertyAsInt(COMMIT_MIN_RETRY_WAIT_MS, COMMIT_MIN_RETRY_WAIT_MS_DEFAULT), // 100
  //              base.propertyAsInt(COMMIT_MAX_RETRY_WAIT_MS, COMMIT_MAX_RETRY_WAIT_MS_DEFAULT), // 60000 (1 min)
  //              base.propertyAsInt(COMMIT_TOTAL_RETRY_TIME_MS, COMMIT_TOTAL_RETRY_TIME_MS_DEFAULT), // 30 minutes
  //              2.0 /* exponential */) // scaleFactor

  // from Tasks
  //           int delayMs =
  //              (int) Math.min(minSleepTimeMs * Math.pow(scaleFactor, attempt - 1), maxSleepTimeMs);
  //          int jitter = ThreadLocalRandom.current().nextInt(Math.max(1, (int) (delayMs * 0.1)));

  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    int attempts = 0;
    rand.nextBytes(deltaScratch);
    while (attempts++ < maxAttempts) {
      logger.trace("update table: {}, key: {}", table, key);
      InputFile in = fileIO.newInputFile(sacriFile);
      try {
        if (in.getLength() + deltaSize > maxFileSize) {
          // CAS
          rand.nextBytes(replScratch);
          readObject(in); // read file to merge
          AtomicOutputFile<CAS> out = fileIO.newOutputFile(in);
          atomicOp(out, replScratch, AtomicOutputFile.Strategy.CAS);
          return Status.OK;
        }
        // APPEND
        AtomicOutputFile<CAS> out = fileIO.newOutputFile(in);
        atomicOp(out, deltaScratch, AtomicOutputFile.Strategy.APPEND);
        return Status.OK;
      } catch (SupportsAtomicOperations.CASException | SupportsAtomicOperations.AppendException e) {
        int delayMs = (int) Math.min(100 * Math.pow(2.0, attempts - 1), 60000);
        int jitter = rand.nextInt(Math.max(1, (int) (delayMs * 0.1)));
        try {
          TimeUnit.MILLISECONDS.sleep(delayMs + jitter);
        } catch (InterruptedException ignored) {
          Thread.currentThread().interrupt();
          return Status.ERROR;
        };
        continue;
      } catch (Exception e) {
          e.printStackTrace(System.out);
          return Status.ERROR;
      }
    }
    return Status.SERVICE_UNAVAILABLE;
  }

  private void readObject(InputFile in) throws IOException {
    try (InputStream i = in.newStream();
         NullOutputStream os = NullOutputStream.NULL_OUTPUT_STREAM) {
      ByteStreams.copy(i, os);
    }
  }

  private void atomicOp(AtomicOutputFile<CAS> out, byte[] data, AtomicOutputFile.Strategy strategy) throws IOException {
    try (ByteArrayInputStream b = new ByteArrayInputStream(data)) {
      b.mark(data.length);
      CAS tok = out.prepare(() -> b, strategy);
      b.reset();
      out.writeAtomic(tok, () -> b);
    }
  }

  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values) {
    return Status.NOT_IMPLEMENTED;
  }

  @Override
  public Status delete(String table, String key) {
    logger.trace("delete table: {}, key: {}", table, key);
    return Status.NOT_IMPLEMENTED;
  }
}
